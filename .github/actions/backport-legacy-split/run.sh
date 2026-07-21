#!/usr/bin/env bash
set -euo pipefail

# Backport a merged monorepo commit into a pre-monorepo (<= v0.36) release line.
#
# The monorepo carries pro code at the repo root and OSS code under a subtree
# prefix (staging/github.com/loft-sh/vcluster). Legacy release branches predate
# that layout: the pro repo keeps pro code at root and pulls OSS via go.mod; the
# OSS repo keeps OSS code at root. A plain cherry-pick of a monorepo commit onto
# a legacy branch is therefore wrong -- for an OSS change it would recreate the
# staging/ tree on the legacy branch instead of patching the real paths.
#
# This action routes by the commit's changed paths:
#
#   pro-only  (nothing under the subtree prefix) -> apply the whole diff onto the
#             pro repo's legacy branch. The legacy pro branch keeps pro code at
#             root -- the same layout as the monorepo root -- so this is a
#             same-path apply, no re-root. (sorenlouv is scoped to the monorepo
#             era >= v0.37 under legacy-split, so it does NOT cover this.)
#   oss-only  (only paths under the subtree prefix) -> re-root the diff to OSS
#             layout and open a backport branch/PR on the OSS repo.
#   mixed     (both) -> split the commit by path into an OSS half and a pro half
#             and open TWO backport branches/PRs, in parallel: the OSS half on
#             the OSS repo, the pro half on the pro repo (carrying its root
#             go.mod diff as-is). No ordering, no release cutting; humans
#             sequence the two merges and reconcile the loft-sh/vcluster pin.
#
# Re-root primitive: `git diff --relative=<prefix> <sha>^ <sha>` both filters the
# diff to the subtree AND strips the prefix, yielding an OSS-rooted patch that
# `git apply` lands on the OSS checkout. This is NOT `git subtree split` (which
# re-roots full history and is the wrong tool for a single commit).
#
# 3-way apply across repos: `git apply --3way` needs the patch's preimage blobs
# present in the target repo, otherwise it fails wholesale on any divergence.
# The re-rooted patch keeps blob *content* (only path headers change), so we
# expose the monorepo's object store to the target checkout via an alternates
# link; --3way then matches preimage blobs by content SHA and produces real
# conflict markers on divergent legacy code (parity with the backport tool's
# commitConflicts=true). Conflicts are committed as-is and <side>-conflicts=true
# is emitted so the caller can label the PR for manual resolution.
#
# Required environment variables:
#   SUBTREE_PREFIX  Subtree path in the monorepo, e.g.
#                   staging/github.com/loft-sh/vcluster. Requires a full-history
#                   checkout of the monorepo as CWD (fetch-depth: 0).
#   TARGET_BRANCH   Legacy release branch to backport onto, e.g. v0.35.
#   OSS_REMOTE      Pushable URL/path of the OSS repo (loft-sh/vcluster).
#                   Required for oss-only and mixed.
#   PRO_REMOTE      Pushable URL/path of the pro repo (vcluster-pro).
#                   Required for pro-only and mixed.
#
# What we backport is the PR's own change set. When PR_NUMBER is set we fetch the
# PR head (refs/pull/N/head) and diff `merge-base(COMMIT^1, PR_HEAD)..PR_HEAD` --
# exactly GitHub's "Files changed". Anchoring on the merge commit's FIRST parent
# makes this correct for every strategy: squash flattens and rebase replays (PR
# head unchanged either way), and for a true merge commit the PR head is the 2nd
# parent -- so merge-base against COMMIT itself would collapse to the PR head and
# diff empty, whereas the first parent is the base side and gives the real fork
# point. It also excludes base-branch drift (the merge base is the stable fork
# point), with no reliance on the mutable pull_request.base.sha. Without PR_NUMBER
# (standalone/tests) it falls back to COMMIT^..COMMIT (single-commit / squash).
#
# Optional environment variables:
#   COMMIT          Monorepo merge commit to backport (default HEAD). Names the
#                   backport branch; also the diff HEAD in the fallback path.
#   PR_NUMBER       Source PR number. When set, the PR head is fetched from
#                   refs/pull/N/head (needs GH_TOKEN) and the diff range is
#                   merge-base(COMMIT^1, PR_HEAD)..PR_HEAD. Unset (tests) uses
#                   COMMIT^..COMMIT.
#   CREATE_PR       "true" opens a PR per pushed branch via gh; "false" pushes
#                   branches only. Unset defaults to "false" for standalone/test
#                   runs; the action.yml `create-pr` input defaults to "true".
#                   Requires GH_TOKEN and OSS_REPO / PRO_REPO (owner/repo slugs).
#   OSS_REPO        owner/repo slug for `gh pr create` on the OSS side.
#   PRO_REPO        owner/repo slug for `gh pr create` on the pro side.
#   WORKDIR         Scratch dir for target checkouts (default: mktemp -d).
#   GITHUB_OUTPUT   Standard Actions output file; defaults to /dev/null so the
#                   script is runnable outside CI.

SUBTREE_PREFIX="${SUBTREE_PREFIX:?SUBTREE_PREFIX is required}"
SUBTREE_PREFIX="${SUBTREE_PREFIX%/}"   # normalize: match on component boundaries
TARGET_BRANCH="${TARGET_BRANCH:?TARGET_BRANCH is required}"
COMMIT="${COMMIT:-}"; [ -n "$COMMIT" ] || COMMIT=HEAD
CREATE_PR="${CREATE_PR:-false}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
WORKDIR="${WORKDIR:-$(mktemp -d)}"
mkdir -p "$WORKDIR"

MONOREPO_DIR="$(git rev-parse --show-toplevel)"
MONO_OBJECTS="$(git -C "$MONOREPO_DIR" rev-parse --absolute-git-dir)/objects"

emit() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }

# Run git with the PAT supplied via http.extraheader in the ENVIRONMENT (never
# argv), so token-bearing clone/fetch/push never leak the credential into `ps` or
# a persisted .git/config. Remotes are token-less URLs (see action.yml). No-op
# auth when GH_TOKEN is unset (standalone/tests against local-path remotes).
git_auth() {
  if [ -n "${GH_TOKEN:-}" ]; then
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader \
      GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')" \
      git "$@"
  else
    git "$@"
  fi
}

# Defaults so callers can read every output unconditionally.
emit route ""
emit backport-branch ""
emit oss-pushed false
emit pro-pushed false
emit oss-conflicts false
emit pro-conflicts false

SHA="$(git rev-parse "$COMMIT")"
SHORT="$(git rev-parse --short "$COMMIT")"
BACKPORT_BRANCH="backport/${TARGET_BRANCH}/${SHORT}"
emit backport-branch "$BACKPORT_BRANCH"

# --- diff range ------------------------------------------------------------
# We backport what the PR changed. Deriving that from the merge commit alone is
# unreliable: COMMIT^ is the base only for a squash/merge-commit; a rebase-merge
# replays each commit, so COMMIT^ would be just the last one. Instead, when
# PR_NUMBER is set we fetch the PR's own head (refs/pull/N/head) and diff from its
# merge base to it -- exactly GitHub's "Files changed". That is correct for every
# merge strategy AND excludes base-branch drift (the merge base is the stable fork
# point), with no dependency on the mutable pull_request.base.sha. Without
# PR_NUMBER (standalone/tests) we fall back to COMMIT^..COMMIT (single-commit).
DIFF_HEAD="$SHA"
if [ -n "${PR_NUMBER:-}" ]; then
  : "${GH_TOKEN:?GH_TOKEN is required to fetch the PR head}"
  # git_auth keeps the credential off argv (see helper); the checkout uses
  # persist-credentials:false and these repos are private.
  if ! fetch_err="$(git_auth fetch -q --no-tags origin "refs/pull/${PR_NUMBER}/head" 2>&1)"; then
    echo "::error::failed to fetch refs/pull/${PR_NUMBER}/head (needed to compute the PR's full diff)"
    [ -n "$fetch_err" ] && echo "${fetch_err//${GH_TOKEN}/***}"
    exit 1
  fi
  PR_HEAD="$(git rev-parse FETCH_HEAD)"
  DIFF_HEAD="$PR_HEAD"
  # Anchor the merge base on the merge commit's FIRST parent. For a true merge
  # commit the PR head is the 2nd parent, so merge-base(merge_commit, pr_head)
  # would collapse to pr_head and yield an empty diff; the first parent is the
  # base side, so its merge base with the PR head is the real fork point. This is
  # the fork point for squash and rebase too, so it's correct for every strategy.
  DIFF_BASE="$(git merge-base "${SHA}^1" "$PR_HEAD")" \
    || { echo "::error::no merge base between ${SHA}^1 and PR head ${PR_HEAD}"; exit 1; }
else
  DIFF_BASE="${SHA}^"
fi
echo "diff range: ${DIFF_BASE} .. ${DIFF_HEAD}"

# Files the PR changed -- drives classification. core.quotePath=false so a
# non-ASCII path isn't dquote/octal-escaped (which would break the
# "${SUBTREE_PREFIX}"/* match and misroute the commit).
# Capture into a variable first: `mapfile < <(git diff ...)` reads from a process
# substitution, so a git-diff failure is invisible to `set -euo pipefail`
# (mapfile succeeds with zero lines) and would surface as the misleading "changes
# no files" below instead of the real error.
changed_raw="$(git -c core.quotePath=false diff --name-only "${DIFF_BASE}" "${DIFF_HEAD}")" \
  || { echo "::error::git diff ${DIFF_BASE}..${DIFF_HEAD} failed"; exit 1; }
mapfile -t changed <<<"$changed_raw"

# --- classify changed paths ------------------------------------------------
oss=false
pro=false
for f in "${changed[@]}"; do
  case "$f" in
    "") ;;
    "${SUBTREE_PREFIX}"/*) oss=true ;;
    *) pro=true ;;
  esac
done

if $oss && $pro; then
  route="mixed"
elif $oss; then
  route="oss-only"
elif $pro; then
  route="pro-only"
else
  echo "::error::commit ${SHA} changes no files"
  exit 1
fi
emit route "$route"
echo "route=${route} (oss=${oss} pro=${pro}) commit=${SHA} target=${TARGET_BRANCH}"

# backport_side <side> <remote> <slug> <patch-file>
#
# Clones TARGET_BRANCH from <remote>, applies <patch-file> with a 3-way merge
# (conflict markers on divergence), commits, pushes the backport branch, and --
# when CREATE_PR=true -- opens a PR on <slug> via gh.
backport_side() {
  local side="$1" remote="$2" slug="$3" patch="$4"
  local checkout="${WORKDIR}/${side}"

  if [ ! -s "$patch" ]; then
    echo "::warning::${side}: empty patch for ${route}; skipping"
    return 0
  fi

  # Before any git work: if a PR is already open for this head->base -- or we
  # can't tell -- leave the branch and PR untouched and skip. The conflicted-PR
  # flow means a human may have resolved markers directly on that branch, so a
  # re-run (e.g. a re-labeled source PR) must not clobber it; checking first also
  # avoids a throwaway clone/apply/commit. Fail safe: keep gh's exit status
  # separate from its output (a `|| true` would conflate a transient query
  # failure with a genuine "no PR" and then clobber + fail the create).
  if [ "$CREATE_PR" = "true" ]; then
    : "${slug:?repo slug (OSS_REPO/PRO_REPO) is required when CREATE_PR=true}"
    : "${GH_TOKEN:?GH_TOKEN is required when CREATE_PR=true}"
    local existing="" rc=0
    existing="$(gh pr list --repo "$slug" --head "$BACKPORT_BRANCH" --base "$TARGET_BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "::warning::${side}: could not query open PRs (gh exit ${rc}); leaving branch and PR as-is rather than risk clobbering an open PR. Re-run to retry."
      return 0
    fi
    if [ -n "$existing" ]; then
      echo "${side}: PR #${existing} already open for ${BACKPORT_BRANCH} -> ${TARGET_BRANCH}; leaving branch and PR as-is (may hold manual conflict resolution)"
      return 0
    fi
  fi

  # Capture stderr so a real failure (auth, network) is surfaced instead of being
  # silently misattributed to a missing branch. git_auth supplies credentials via
  # the environment; the remote URL is token-less, but scrub it anyway for tidiness.
  local clone_err
  if ! clone_err="$(git_auth clone -q --branch "$TARGET_BRANCH" --single-branch "$remote" "$checkout" 2>&1)"; then
    echo "::error::${side}: failed to clone branch '${TARGET_BRANCH}' from ${slug:-the target repo} (missing branch, auth, or network)"
    [ -n "$clone_err" ] && echo "${clone_err//${remote}/<remote>}"
    exit 1
  fi
  git -C "$checkout" checkout -q -b "$BACKPORT_BRANCH"

  # Expose the monorepo's objects to the target checkout so `git apply --3way`
  # can find the patch's preimage blobs by content SHA (see header).
  echo "$MONO_OBJECTS" >> "${checkout}/.git/objects/info/alternates"

  # A conflicted 3-way apply leaves the index unmerged; `git add -A` below stages
  # the marked files (parity with the backport tool's commitConflicts=true), so
  # the branch is created BEFORE applying.
  local conflicts=false
  if git -C "$checkout" apply --3way --whitespace=nowarn "$patch"; then
    echo "${side}: patch applied cleanly"
  else
    conflicts=true
    echo "::warning::${side}: applied with conflicts; opening a conflicted PR for manual resolution"
  fi

  local msg="backport: ${SHORT} to ${TARGET_BRANCH} (${side})

Backport of monorepo commit ${SHA} (${side} half) onto ${TARGET_BRANCH}."
  if [ "$conflicts" = true ]; then
    msg="${msg}

Applied with merge conflicts that need manual resolution."
  fi

  git -C "$checkout" add -A
  # Anything staged (clean changes OR conflict markers) -> commit below. Nothing
  # staged has two causes to separate:
  #   already applied -> the patch's net effect (incl. a deletion/rename, which a
  #     forward --3way reports as a failure rather than a no-op) is ALREADY on the
  #     branch, e.g. a re-backport / re-label. A clean REVERSE apply proves this.
  #     Skip.
  #   genuinely unappliable -> reverse-check also fails (e.g. a file the patch
  #     changes was deleted/renamed on the legacy branch). Fail loudly rather than
  #     let `git commit` emit an opaque "nothing to commit" and crash the job.
  if git -C "$checkout" diff --cached --quiet; then
    if git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null; then
      echo "::warning::${side}: no changes to apply (already present on ${TARGET_BRANCH}?); skipping"
      return 0
    fi
    echo "::error::${side}: cannot 3-way apply onto ${TARGET_BRANCH} -- a file the patch changes was likely deleted or renamed on the legacy branch (or is absent there). Resolve manually."
    exit 1
  fi
  # Emit only on the commit path so a skipped/failed side keeps the default
  # <side>-conflicts=false (emitted up front) rather than a phantom true.
  emit "${side}-conflicts" "$conflicts"
  # $checkout is a fresh `git clone` of the target repo (see above), NOT the
  # actions/checkout workspace -- so it inherits no user.name/user.email and an
  # unqualified `git commit` dies with "empty ident name". Set the bot identity
  # inline (both author and committer) rather than depending on ambient config.
  git -C "$checkout" \
    -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "$msg"

  # No open PR (checked before cloning), so nothing to protect: (re)create the
  # branch. Force keeps a re-run before the PR exists idempotent -- e.g. a
  # leftover branch from a prior run whose PR creation failed -- instead of
  # failing on a non-fast-forward. The branch name is deterministic
  # (backport/<target>/<short-sha>). Capture output and scrub $remote (which may
  # carry a token in its URL) so a push failure can't leak it to the log; git
  # prints the remote URL on its "To <remote>" / error lines.
  local push_err
  if ! push_err="$(git_auth -C "$checkout" push --force "$remote" "$BACKPORT_BRANCH" 2>&1)"; then
    echo "::error::${side}: failed to push ${BACKPORT_BRANCH} to ${slug:-the target repo}"
    [ -n "$push_err" ] && echo "${push_err//${remote}/<remote>}"
    exit 1
  fi
  emit "${side}-pushed" true
  echo "${side}: pushed ${BACKPORT_BRANCH} -> ${slug:-the target repo}"

  if [ "$CREATE_PR" = "true" ]; then
    local title body
    title="[${TARGET_BRANCH}] backport ${SHORT} (${side})"
    body="Automated backport of \`${SHA}\` (${side} half) onto \`${TARGET_BRANCH}\`."
    local -a create_args=(--repo "$slug" --head "$BACKPORT_BRANCH" --base "$TARGET_BRANCH" --title "$title")
    if [ "$conflicts" = true ]; then
      # Open as a DRAFT so it cannot be auto-merged: the committed conflict
      # markers are valid content (git reports the PR mergeable), and
      # auto-approve-bot-prs approves any `backport/` PR from a trusted author --
      # a draft is the one state GitHub refuses to merge until a human marks it
      # ready. Resolve the markers, then mark ready for review.
      body="${body}

> :warning: Applied with **merge conflicts**. Opened as a draft so it can't be
> auto-merged. Resolve the conflict markers, then mark this PR ready for review."
      create_args+=(--draft)
    fi
    gh pr create "${create_args[@]}" --body "$body"
  fi
}

# OSS half (oss-only and mixed): re-root staging/... to OSS layout.
if [ "$route" = "oss-only" ] || [ "$route" = "mixed" ]; then
  : "${OSS_REMOTE:?OSS_REMOTE is required for ${route}}"
  # Trailing slash: match on a component boundary so a sibling module dir sharing
  # the prefix string (e.g. staging/.../vcluster-pro) can't leak into the OSS
  # patch. --binary: carry binary file changes (a plain diff emits an unappliable
  # "Binary files differ" placeholder).
  git diff --binary --relative="${SUBTREE_PREFIX}/" "${DIFF_BASE}" "${DIFF_HEAD}" > "${WORKDIR}/oss.patch"
  backport_side oss "$OSS_REMOTE" "${OSS_REPO:-}" "${WORKDIR}/oss.patch"
fi

# Pro side (pro-only and mixed): everything outside the subtree, including root
# go.mod. For pro-only this is the whole commit; the legacy pro branch is the
# same root layout as the monorepo root, so it applies without re-rooting.
if [ "$route" = "pro-only" ] || [ "$route" = "mixed" ]; then
  : "${PRO_REMOTE:?PRO_REMOTE is required for ${route}}"
  # In a mixed backport the OSS half above already pushed its branch / opened its
  # PR; if the pro half below fails, this note keeps the partial-completion
  # context in the annotations so the operator knows a plain re-run retries the
  # pro side (the finished OSS side is skipped via its open-PR guard).
  if [ "$route" = "mixed" ]; then
    echo "::notice::mixed backport: OSS half done; if the pro half fails, re-run to retry it (OSS side is skipped via its open PR). If the OSS PR was merged/closed meanwhile, finish the pro side manually."
  fi
  git diff --binary "${DIFF_BASE}" "${DIFF_HEAD}" -- . ":(exclude)${SUBTREE_PREFIX}" > "${WORKDIR}/pro.patch"
  backport_side pro "$PRO_REMOTE" "${PRO_REPO:-}" "${WORKDIR}/pro.patch"
fi

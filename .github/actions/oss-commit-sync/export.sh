#!/usr/bin/env bash
set -euo pipefail

# Export monorepo commits touching SUBTREE_PREFIX to the OSS repository.
#
# Every first-parent monorepo commit after the resume point that touches the
# subtree becomes its own OSS commit: the commit's diff is re-rooted with
# --relative and 3-way applied on top of the OSS branch tip, preserving
# author, date, and message, plus a "Monorepo-Commit: <sha>" trailer. Commits
# carrying an "Oss-Commit:" trailer originated on OSS and are skipped (loop
# guard). Pushes are plain fast-forwards; nothing is ever force-pushed.
#
# Resume point: the newest Monorepo-Commit trailer on the OSS branch. Diff
# replay (not tree snapshots) is what makes interleaving safe: an external
# OSS commit that is already absorbed into the subtree is never reverted by
# a replayed company commit, because only the company commit's own changes
# are applied.
#
# Divergence guard: before replaying, every OSS commit since the resume
# anchor that we did not create must already be absorbed into the monorepo
# (appear as an Oss-Commit trailer). Otherwise replaying could interleave
# with unreviewed external work; we fail closed and the caller dispatches
# the import direction.
#
# Convergence assertion: after replay, the OSS tip tree must equal the
# monorepo staging tree. A mismatch fails the run; ALIGN_TREE=true instead
# appends a bot-authored alignment commit that sets the OSS tree to the
# staging tree (used once at migration to drop the producer workflows, and
# as the append-only escape hatch that replaces force-pushing).
#
# New branches (fresh release lines): when BRANCH does not exist on OSS, the
# anchor is discovered by walking the monorepo branch back to the newest
# commit already present on the OSS default branch (via either trailer
# direction), and the OSS branch is created from that commit.
#
# Required env: SUBTREE_PREFIX, OSS_REMOTE (pushable URL; tests use a local
# path), BRANCH.
# Optional env: OSS_DEFAULT_BRANCH (default main), SEED_MONOREPO_COMMIT +
# SEED_OSS_COMMIT (first run on a pre-existing branch with no trailers),
# ALIGN_TREE (default false), EXCLUDE_PATHS (newline-separated OSS-root
# paths that are never mirrored; the guard and the convergence assertion
# ignore them), GITHUB_OUTPUT.
#
# Outputs: pushed, diverged, push-rejected, exported-count, oss-tip,
# loose-absorption.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBTREE_PREFIX="${SUBTREE_PREFIX:?SUBTREE_PREFIX is required}"
OSS_REMOTE="${OSS_REMOTE:?OSS_REMOTE is required}"
BRANCH="${BRANCH:?BRANCH is required}"
OSS_DEFAULT_BRANCH="${OSS_DEFAULT_BRANCH:-main}"
SEED_MONOREPO_COMMIT="${SEED_MONOREPO_COMMIT:-}"
SEED_OSS_COMMIT="${SEED_OSS_COMMIT:-}"
ALIGN_TREE="${ALIGN_TREE:-false}"
EXCLUDE_PATHS="${EXCLUDE_PATHS:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

cd "$(git rev-parse --show-toplevel)"

build_excludes

emit diverged false
emit pushed false
emit push-rejected false
emit exported-count 0
emit loose-absorption false

# Declared before the branch split so the alignment gate can test it unguarded on
# both paths. It stays empty on the fresh-branch path, which never runs the
# divergence guard and so never classifies evidence: alignment there is not gated,
# exactly as it was before this guard existed. That path builds a branch from the
# default branch's trailers rather than reconciling against an existing one, and
# giving it the same treatment is a separate change.
loose_absorbed=()

# --- locate the OSS branch tip and the resume point ------------------------

# Probe branch existence; exit 2 means "absent", anything else non-zero is a
# transport/auth failure that must not be mistaken for a first push.
branch_absent=false
ls_status=0
ls_err="$(git ls-remote --exit-code --heads "$OSS_REMOTE" "refs/heads/${BRANCH}" 2>&1 >/dev/null)" || ls_status=$?
if [ "$ls_status" -eq 2 ]; then
  branch_absent=true
elif [ "$ls_status" -ne 0 ]; then
  [ -n "$ls_err" ] && echo "${ls_err//${OSS_REMOTE}/<oss-remote>}"
  die "failed to query OSS branch ${BRANCH} (git ls-remote exit ${ls_status}); refusing to sync"
fi

if [ "$branch_absent" = "false" ]; then
  git_scrubbed fetch --quiet "$OSS_REMOTE" "refs/heads/${BRANCH}"
  OSS_TIP="$(git rev-parse FETCH_HEAD)"

  entry="$(newest_trailer_entry "$OSS_TIP" "$MONOREPO_TRAILER")"
  if [ -n "$entry" ]; then
    OSS_ANCHOR="${entry%% *}"
    RESUME="${entry#* }"
  elif [ -n "$SEED_MONOREPO_COMMIT" ] && [ -n "$SEED_OSS_COMMIT" ]; then
    OSS_ANCHOR="$SEED_OSS_COMMIT"
    RESUME="$SEED_MONOREPO_COMMIT"
  else
    die "no ${MONOREPO_TRAILER} trailer found on OSS ${BRANCH} and no seed provided; set SEED_MONOREPO_COMMIT + SEED_OSS_COMMIT for the first run"
  fi

  git cat-file -e "${RESUME}^{commit}" \
    || die "resume point ${RESUME} (from ${MONOREPO_TRAILER} trailer) is not a commit in this repo"
  git merge-base --is-ancestor "$OSS_ANCHOR" "$OSS_TIP" \
    || die "resume anchor ${OSS_ANCHOR} is not an ancestor of OSS ${BRANCH} tip"

  # Divergence guard: every OSS commit we did not create must already be
  # absorbed (present as an Oss-Commit trailer on our first-parent chain).
  # The walk is bounded to RESUME..HEAD: an external commit in
  # OSS_ANCHOR..OSS_TIP landed after RESUME's export was pushed, so its
  # absorption commit was necessarily merged after RESUME on the first-parent
  # chain. Older absorptions belong to externals before the anchor, which the
  # guard never inspects.
  #
  # every_trailer_value, not the last-wins lookup: one squash-merged import PR
  # records every commit it replayed on a single commit, and all of them count
  # as absorbed. Piped through resolve_sha_set because the shas below are full
  # length while a trailer value may be abbreviated, and grep -x would never
  # match those.
  absorbed_file="$(mktemp)"
  every_trailer_value "${RESUME}..HEAD" "$OSS_TRAILER" | resolve_sha_set > "$absorbed_file"
  # The same values as git's own trailer parser sees them, which is BOTH a wider
  # and a narrower set than the scan above.
  #
  # Wider: git accepts forms trailer_scan ignores ("Oss-Commit:<sha>" with no
  # space, several spaces, a tab, uppercase hex), so a record git reads perfectly
  # can be invisible to the scan. Those must count as absorbed too, or the export
  # deadlocks on a commit whose trailer is right there in the block.
  #
  # Narrower: the scan reads the whole message on purpose, so it also reads an
  # Oss-Commit line quoted at column 0 in a body. No textual rule separates that
  # from a real trailer, because the neighbouring line may be "Signed-off-by: x"
  # or "Note: still pending is" and both are trailer-shaped. So a value the block
  # does not carry still counts, and is merely recorded as weaker evidence for the
  # align-tree gate further down.
  # unfold is load-bearing, not tidiness: without it a folded value stays several
  # physical lines, so
  #     Oss-Commit:<sha>
  #       this was not an absorption record
  # would hand its first line to the shape filter and promote a sha nobody
  # recorded to the strongest evidence there is. Unfolded, the whole value arrives
  # on one line and fails the hex test, which is the correct answer.
  block_absorbed_file="$(mktemp)"
  git log --first-parent --format="%(trailers:key=${OSS_TRAILER},valueonly,unfold)" "${RESUME}..HEAD" \
    | filter_sha_values | resolve_sha_set > "$block_absorbed_file"
  cat "$block_absorbed_file" >> "$absorbed_file"
  unabsorbed=()
  loose_absorbed=()
  # Captured first: a failing command substitution in a `for` word list is
  # invisible to set -e, so the guard would run zero times, leave both arrays empty
  # and let the run proceed -- with align-tree that flattens the OSS tree with no
  # gate at all. Every other producer here is captured and checked for this reason.
  if ! externals="$(git rev-list --first-parent "${OSS_ANCHOR}..${OSS_TIP}")"; then
    die "failed to list OSS commits in ${OSS_ANCHOR}..${OSS_TIP}; refusing to judge divergence"
  fi
  for s in $externals; do
    has_trailer "$s" "$MONOREPO_TRAILER" && continue
    if grep -qxF "$s" "$absorbed_file"; then
      grep -qxF "$s" "$block_absorbed_file" && continue
      # Absorbed on evidence git's parser cannot see. Harmless unless alignment
      # could delete the commit's content, so ask the content question first:
      # benign means the content is already in the subtree, or lives only in
      # excluded paths, and there is nothing for alignment to remove.
      external_is_benign "$s" && continue
      # Only recorded here. The refusal lives at the alignment commit itself: this
      # evidence is weak enough to decline a destructive overwrite and nowhere near
      # weak enough to decline an ordinary export, so deciding it here would fail
      # runs whose trees already agree and where alignment would create nothing.
      loose_absorbed+=("$s")
      continue
    fi
    if external_is_benign "$s"; then
      echo "External ${s} is benign (excluded paths only, or content already in ${SUBTREE_PREFIX})"
      continue
    fi
    unabsorbed+=("$s")
  done
  rm -f "$absorbed_file" "$block_absorbed_file"
  # Emitted before the divergence exit below, or a run that has both a loose
  # absorption and a genuine divergence would report loose-absorption=false and
  # hide half of what it found.
  if [ "${#loose_absorbed[@]}" -gt 0 ]; then
    emit loose-absorption true
    printf '::notice::External %s counts as absorbed only via an Oss-Commit line outside git trailer block\n' "${loose_absorbed[@]}"
  fi
  if [ "${#unabsorbed[@]}" -gt 0 ]; then
    emit diverged true
    echo "::error::OSS ${BRANCH} has external commits not yet absorbed into ${SUBTREE_PREFIX}:"
    printf '::error::  %s\n' "${unabsorbed[@]}"
    echo "::error::Run the import direction (sync-from-oss) and merge its PR, then retry."
    exit 1
  fi
else
  # Fresh release line: anchor where the monorepo branch history was last
  # known to OSS, via either trailer direction on the OSS default branch.
  git_scrubbed fetch --quiet "$OSS_REMOTE" "refs/heads/${OSS_DEFAULT_BRANCH}"
  DEFAULT_TIP="$(git rev-parse FETCH_HEAD)"

  exported_map="$(mktemp)"
  all_trailer_entries "$DEFAULT_TIP" "$MONOREPO_TRAILER" | awk '{print $2 "\t" $1}' > "$exported_map"

  RESUME=""
  OSS_TIP=""
  while read -r m; do
    oss_sha="$(awk -F'\t' -v k="$m" '$1 == k { print $2; exit }' "$exported_map")"
    if [ -n "$oss_sha" ]; then
      RESUME="$m"
      OSS_TIP="$oss_sha"
      break
    fi
    imported_from="$(trailer_value "$m" "$OSS_TRAILER")"
    if [ -n "$imported_from" ] && git merge-base --is-ancestor "$imported_from" "$DEFAULT_TIP" 2>/dev/null; then
      RESUME="$m"
      OSS_TIP="$imported_from"
      break
    fi
  done < <(git rev-list --first-parent HEAD)
  rm -f "$exported_map"

  [ -n "$RESUME" ] \
    || die "cannot anchor new OSS branch ${BRANCH}: no commit on this branch is known to OSS ${OSS_DEFAULT_BRANCH}"
  echo "OSS ${BRANCH} does not exist; creating it from ${OSS_TIP} (monorepo ${RESUME})"
fi

# --- replay -----------------------------------------------------------------

WT_PARENT="$(mktemp -d)"
WT="${WT_PARENT}/oss"
git worktree add --detach --quiet "$WT" "$OSS_TIP"
trap 'git worktree remove --force "$WT" 2>/dev/null || true; rm -rf "$WT_PARENT"' EXIT

count=0
while read -r M; do
  [ -n "$M" ] || continue
  ensure_not_merge "$M"
  if has_trailer "$M" "$OSS_TRAILER"; then
    echo "Skipping ${M} (originated on OSS)"
    continue
  fi
  # The trailing slash matters: --relative does string-prefix matching, so
  # without it a prefix-sharing sibling directory (vcluster-foo/) would leak
  # into the re-rooted diff.
  patch="$(git diff-tree --no-commit-id -p --binary -M --relative="${SUBTREE_PREFIX}/" "$M")"
  if [ -z "$patch" ]; then
    echo "Skipping ${M} (empty diff under ${SUBTREE_PREFIX})"
    continue
  fi
  if ! printf '%s\n' "$patch" | git -C "$WT" apply --3way --whitespace=nowarn; then
    git -C "$WT" reset --hard --quiet
    git -C "$WT" clean -fdq
    die "conflict replaying ${M} onto OSS ${BRANCH}; resolve by importing OSS first or inspect the commit"
  fi
  git -C "$WT" add -A
  if nothing_staged "$WT"; then
    echo "Skipping ${M} (applies as a no-op; content already on OSS)"
    continue
  fi
  replay_commit "$M" "$MONOREPO_TRAILER" "$WT"
  count=$((count + 1))
  echo "Replayed ${M} -> $(git -C "$WT" rev-parse HEAD) ($(git log -1 --format=%s "$M"))"
done < <(git rev-list --reverse --first-parent "${RESUME}..HEAD" -- "$SUBTREE_PREFIX")

NEW_TIP="$(git -C "$WT" rev-parse HEAD)"

# --- convergence assertion ---------------------------------------------------

# The assertion ignores excluded paths: they are never mirrored, so an
# external commit touching only them may legitimately leave the OSS tree
# differing there. ALIGN_TREE=true instead aligns on ANY difference,
# including excluded paths: it is the explicit operator escape hatch, and at
# migration this is what deletes the OSS-only producer workflows and seeds
# the first Monorepo-Commit trailer.
STAGING_TREE="$(git rev-parse "HEAD:${SUBTREE_PREFIX}")"
OSS_TREE="$(git -C "$WT" rev-parse "HEAD^{tree}")"
if [ "$STAGING_TREE" != "$OSS_TREE" ]; then
  if [ "$ALIGN_TREE" = "true" ]; then
    # The one place the weak evidence matters: this commit sets the OSS tree to the
    # staging tree, deleting whatever OSS holds and staging does not. An external
    # absorbed only by a line outside git's trailer block may be one of those, and
    # "never absorbed" is indistinguishable from "absorbed, then superseded" by
    # content alone, so the value's origin is the only signal left.
    if [ "${#loose_absorbed[@]}" -gt 0 ]; then
      echo "::error::align-tree would overwrite the OSS tree, deleting anything OSS holds that ${SUBTREE_PREFIX} does not, while these external commits are absorbed only by an ${OSS_TRAILER} line outside git's trailer block:"
      printf '::error::  %s\n' "${loose_absorbed[@]}"
      echo "::error::That evidence is enough to keep exporting, not to delete their content from OSS."
      # Deliberately not "run the import direction": the anchor comes from the same
      # whole-message scan, so it already reaches past these commits and the import
      # has nothing to replay. Saying otherwise sends the operator, or a caller
      # dispatching on an output, round a loop that cannot terminate.
      echo "::error::The import direction cannot clear this: the anchor already reaches past them, so it has nothing to replay. Decide per commit."
      echo "::error::  absorbed, then superseded upstream -> record it where git's own parser reads it, i.e. an empty commit on ${BRANCH} whose message ends with a paragraph containing only '${OSS_TRAILER}: <sha>', then re-run with align-tree."
      # Not seed-oss-commit: the seed is a forward floor only (it replaces the
      # anchor when the anchor is an ancestor of it), so a seed placed behind the
      # falsely recorded commit is silently ignored and the import still resumes
      # past it. Bringing the content in is the recovery that works.
      echo "::error::  not absorbed -> apply that OSS commit's changes under ${SUBTREE_PREFIX} and commit them, so its content is present. Then align-tree has nothing to delete. Do not add a trailer for it, and do not expect seed-oss-commit to help: it only moves the anchor forward."
      exit 1
    fi
    msgfile="$(mktemp)"
    {
      echo "chore: align OSS mirror with monorepo staging tree"
      echo
      echo "Snapshot alignment requested via align-tree; sets the OSS tree to the"
      echo "monorepo subtree content in one append-only commit."
      echo
      echo "${MONOREPO_TRAILER}: $(git rev-parse HEAD)"
    } > "$msgfile"
    NEW_TIP="$(git commit-tree "$STAGING_TREE" -p "$NEW_TIP" -F "$msgfile")"
    rm -f "$msgfile"
    count=$((count + 1))
    echo "Appended alignment commit ${NEW_TIP}"
  elif ! git diff --quiet "$OSS_TREE" "$STAGING_TREE" -- . ${excludes[@]+"${excludes[@]}"}; then
    echo "::error::OSS tree does not match the monorepo staging tree after replay:"
    git --no-pager diff --stat "$OSS_TREE" "$STAGING_TREE" -- . ${excludes[@]+"${excludes[@]}"} || true
    echo "::error::Re-run with align-tree=true to append a snapshot alignment commit."
    exit 1
  else
    echo "OSS tree differs from staging only in excluded paths; leaving them as-is"
  fi
fi

# --- push (plain fast-forward; branch creation for new lines) ---------------

if [ "$NEW_TIP" != "$OSS_TIP" ] || [ "$branch_absent" = "true" ]; then
  # A true pre-push permission check isn't possible: server-side rulesets are
  # not evaluated on --dry-run, and a token with write access can still be
  # blocked by branch protection. So the fail-fast is here: on a rejection,
  # translate git's raw error into an actionable one instead of leaving a bare
  # GH013 in the log.
  if git_scrubbed push --quiet "$OSS_REMOTE" "${NEW_TIP}:refs/heads/${BRANCH}"; then
    emit pushed true
    echo "Pushed ${NEW_TIP} to OSS ${BRANCH}"
  else
    emit push-rejected true
    echo "::error::Push to OSS ${BRANCH} was rejected. If this is a branch-protection / ruleset rejection (GH013, 'must be made through a pull request', or 'not authorized to push'), the sync identity is not a bypass actor. It must bypass EVERY protection targeting ${BRANCH}: all repository/organization rulesets (require-PR bypass) AND legacy branch protection (require-PR bypass + push allowlist). Team bypass actors only apply if the team has access to the repo. See the oss-commit-sync README 'Prerequisites'."
    exit 1
  fi
else
  echo "Nothing to push; OSS ${BRANCH} is up to date"
fi
emit exported-count "$count"
emit oss-tip "$NEW_TIP"

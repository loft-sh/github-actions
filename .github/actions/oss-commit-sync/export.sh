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

# loose_absorption_recovery
# What to do about an external absorbed only by a line outside git's trailer
# block. Printed from both places that stop on one, so the two cannot drift: the
# alignment gate, which refuses the overwrite, and the convergence assertion,
# which reaches the same commits by the other road.
loose_absorption_recovery() {
  # The monorepo branch, not ${BRANCH}: the block set is read from this repo's
  # own first-parent chain (RESUME..HEAD), so a commit pushed to OSS instead
  # changes nothing and every retry fails the same way.
  echo "::error::  absorbed, then superseded upstream -> record it where git's own parser reads it, i.e. an empty commit on the monorepo branch this action runs from, whose message ends with a paragraph containing only '${OSS_TRAILER}: <sha>', then re-run with align-tree."
  # Not seed-oss-commit: the seed is a forward floor only (it replaces the
  # anchor when the anchor is an ancestor of it), so a seed placed behind the
  # falsely recorded commit is silently ignored and the import still resumes
  # past it. Bringing the content in is the recovery that works.
  echo "::error::  not absorbed -> apply that OSS commit's changes under ${SUBTREE_PREFIX} and commit them, so its content is present. Then align-tree has nothing to delete. Do not add a trailer for it, and do not expect seed-oss-commit to help: it only moves the anchor forward."
}

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
    # Prefix-checked, like every other value read out of a trailer: RESUME may be
    # any 7-40 char hex a human wrote, and `cat-file -e` accepts a value that peels
    # to a commit rather than one that names it, so an abbreviation colliding with
    # an annotated tag resumes the replay from an unrelated commit. Normalised to
    # the full sha so the ranges below are built from what it resolved to.
    resume_rc=0
    resume_full="$(resolve_commit_prefix "$RESUME")" || resume_rc=$?
    if [ "$resume_rc" -eq 2 ]; then
      die "git failed while resolving the resume point ${RESUME} (from ${MONOREPO_TRAILER} trailer); refusing to export"
    elif [ "$resume_rc" -ne 0 ]; then
      die "resume point ${RESUME} (from ${MONOREPO_TRAILER} trailer) is not a commit in this repo"
    fi
    RESUME="$resume_full"
  elif [ -n "$SEED_MONOREPO_COMMIT" ] && [ -n "$SEED_OSS_COMMIT" ]; then
    # NOT prefix-checked: these are typed by an operator doing a first run, and the
    # peel guard exists for values a contributor can write, not for them. Holding
    # the seed to the trailer spelling rejects an uppercase sha and any ref name,
    # both of which git resolves happily, and fails the one path that has no
    # trailer to fall back to with "is not a commit in this repo".
    #
    # Both are stored peeled, so what the ranges below are built from is the commit
    # each seed named rather than, say, the tag object rev-parse printed for it.
    # 2>/dev/null because --quiet still speaks up on a type mismatch, and die says
    # it better.
    RESUME="$(git rev-parse --verify --quiet "${SEED_MONOREPO_COMMIT}^{commit}" 2>/dev/null)" \
      || die "seed resume point ${SEED_MONOREPO_COMMIT} is not a commit in this repo"
    OSS_ANCHOR="$(git rev-parse --verify --quiet "${SEED_OSS_COMMIT}^{commit}" 2>/dev/null)" \
      || die "seed OSS anchor ${SEED_OSS_COMMIT} is not a commit in this repo"
  else
    die "no ${MONOREPO_TRAILER} trailer found on OSS ${BRANCH} and no seed provided; set SEED_MONOREPO_COMMIT + SEED_OSS_COMMIT for the first run"
  fi
  # is_ancestor, not a bare merge-base: rc 128 collapsed into "not an ancestor"
  # reports a rewritten OSS history and sends the operator hunting a force-push
  # that never happened, when the truth is a partial fetch or a broken object
  # store. Both fail closed; only one of them is answerable.
  anchor_rc=0
  is_ancestor "$OSS_ANCHOR" "$OSS_TIP" || anchor_rc=$?
  if [ "$anchor_rc" -eq 2 ]; then
    die "git failed testing whether resume anchor ${OSS_ANCHOR} is on OSS ${BRANCH}; refusing to export"
  elif [ "$anchor_rc" -ne 0 ]; then
    die "resume anchor ${OSS_ANCHOR} is not an ancestor of OSS ${BRANCH} tip"
  fi

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
  # A second, narrower read: only what git's own trailer parser sees. This is a
  # strict subset of the set above, which is why it is not merged into it. It exists
  # to tell strong evidence from weak, nothing else.
  #
  # The scan reads the whole message on purpose, so it also reads an Oss-Commit line
  # quoted at column 0 in a body. No textual rule separates that from a real
  # trailer, because the neighbouring line may be "Signed-off-by: x" or "Note: still
  # pending is" and both are trailer-shaped. Such a value still counts as absorbed;
  # it is merely recorded as weaker evidence for the align-tree gate further down.
  #
  # unfold is load-bearing, not tidiness: without it a folded value stays several
  # physical lines, so
  #     Oss-Commit:<sha>
  #       this was not an absorption record
  # would hand its first line to the shape filter and promote a sha nobody
  # recorded to the strongest evidence there is. Unfolded, the whole value arrives
  # on one line and fails the hex test, which is the correct answer. trailer_scan
  # reaches the same verdict on the same lines, so the two sets cannot disagree
  # about a folded value and call it weak evidence rather than none at all.
  block_absorbed_file="$(mktemp)"
  git log --first-parent --format="%(trailers:key=${OSS_TRAILER},valueonly,unfold)" "${RESUME}..HEAD" \
    | filter_sha_values | resolve_sha_set > "$block_absorbed_file"
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
    ht_rc=0
    has_trailer "$s" "$MONOREPO_TRAILER" || ht_rc=$?
    if [ "$ht_rc" -eq 2 ]; then
      rm -f "$absorbed_file" "$block_absorbed_file"
      die "git failed reading the ${MONOREPO_TRAILER} trailer of ${s}; refusing to judge divergence"
    elif [ "$ht_rc" -eq 0 ]; then
      continue
    fi
    if grep -qxF "$s" "$absorbed_file"; then
      grep -qxF "$s" "$block_absorbed_file" && continue
      # Absorbed on evidence git's parser cannot see. Harmless unless alignment
      # could delete the commit's content, so ask the content question first:
      # benign means the content is already in the subtree, or lives only in
      # excluded paths, and there is nothing for alignment to remove.
      eb_rc=0
      external_is_benign "$s" || eb_rc=$?
      if [ "$eb_rc" -eq 2 ]; then
        rm -f "$absorbed_file" "$block_absorbed_file"
        die "git failed checking whether ${s} is already present in ${SUBTREE_PREFIX}; refusing to classify its absorption evidence"
      elif [ "$eb_rc" -eq 0 ]; then
        continue
      fi
      # Only recorded here. The refusal lives at the alignment commit itself: this
      # evidence is weak enough to decline a destructive overwrite and nowhere near
      # weak enough to decline an ordinary export, so deciding it here would fail
      # runs whose trees already agree and where alignment would create nothing.
      loose_absorbed+=("$s")
      continue
    fi
    eb_rc=0
    external_is_benign "$s" || eb_rc=$?
    if [ "$eb_rc" -eq 2 ]; then
      rm -f "$absorbed_file" "$block_absorbed_file"
      die "git failed checking whether ${s} is already present in ${SUBTREE_PREFIX}; refusing to judge divergence"
    elif [ "$eb_rc" -eq 0 ]; then
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
  # multi=1, not the last-wins lookup: this map answers "was this monorepo commit
  # ever exported", which is the same set-membership question every_trailer_value
  # exists for. An OSS commit carrying several ${MONOREPO_TRAILER} lines -- a
  # squash, or a hand-made export -- hides all but the last under last-wins, so
  # the true branch point goes missing and the new release line is anchored behind
  # where OSS already is, re-replaying commits the mirror holds.
  # Keys resolved, not raw: map_lookup compares exact strings while the walk below
  # queries with a full sha from rev-list, so an abbreviated or hand-written
  # record never matched and the walk fell past the very branch point this map
  # exists to find -- anchoring the release line further back and re-replaying
  # commits OSS already holds. Every other trailer read in this action resolves;
  # this was the last one that did not. Both spellings are emitted so a record
  # that resolves to nothing still matches literally, as before.
  if ! map_rows="$(trailer_scan "$MONOREPO_TRAILER" 1 --first-parent "$DEFAULT_TIP")"; then
    rm -f "$exported_map"
    die "failed to read ${MONOREPO_TRAILER} records on OSS ${OSS_DEFAULT_BRANCH}; refusing to anchor a new OSS branch"
  fi
  map_out=""
  while read -r oss_c val; do
    [ -n "$val" ] || continue
    map_out+="${val}"$'\t'"${oss_c}"$'\n'
    [ "${#val}" -lt 40 ] || continue
    map_rc=0
    val_full="$(resolve_commit_prefix "$val")" || map_rc=$?
    if [ "$map_rc" -eq 2 ]; then
      rm -f "$exported_map"
      die "git failed resolving the ${MONOREPO_TRAILER} value ${val} on ${oss_c}; refusing to anchor a new OSS branch"
    elif [ "$map_rc" -eq 0 ]; then
      map_out+="${val_full}"$'\t'"${oss_c}"$'\n'
    fi
  done <<< "$map_rows"
  printf '%s' "$map_out" > "$exported_map"

  RESUME=""
  OSS_TIP=""
  # Captured, like every other producer here: inside `done < <(...)` a failing
  # rev-list is invisible to set -e, so the loop runs zero times and the run dies
  # with "no commit on this branch is known to OSS", sending the operator after a
  # branch-point problem that does not exist.
  if ! branch_walk="$(git rev-list --first-parent HEAD)"; then
    rm -f "$exported_map"
    die "failed to walk this branch's history; refusing to anchor a new OSS branch"
  fi
  while read -r m; do
    [ -n "$m" ] || continue
    # String-compared inside map_lookup: awk would otherwise rank two all-decimal
    # shas numerically and anchor the new release line at the wrong OSS commit.
    oss_sha="$(map_lookup "$m" "$exported_map")"
    if [ -n "$oss_sha" ]; then
      RESUME="$m"
      OSS_TIP="$oss_sha"
      break
    fi
    # Every recorded import on this commit, not the last line: a squash records
    # several, and if they are not in ancestry order the last one is the nearer.
    # The walk wants the FARTHEST reachable, same as resolve_import_anchor, so it
    # compares them rather than trusting message order.
    if ! imported_values="$(trailer_scan "$OSS_TRAILER" 1 -1 "$m" | awk '{print $2}')"; then
      rm -f "$exported_map"
      die "git failed reading the ${OSS_TRAILER} records on ${m}; refusing to anchor a new OSS branch"
    fi
    imported_best=""
    while read -r imported_from; do
      [ -n "$imported_from" ] || continue
      # Prefix-checked like every other trailer value this action reads, and here
      # it decides the base commit of a branch that does not exist yet. Both the
      # ancestry test below and `git worktree add --detach` PEEL an annotated tag,
      # so an abbreviation that uniquely names a tag object would otherwise pass
      # every check and create the release line from a commit sharing none of the
      # value's digits.
      imp_rc=0
      imported_full="$(resolve_commit_prefix "$imported_from")" || imp_rc=$?
      if [ "$imp_rc" -eq 2 ]; then
        rm -f "$exported_map"
        die "git failed resolving the ${OSS_TRAILER} value ${imported_from} on ${m}; refusing to anchor a new OSS branch"
      elif [ "$imp_rc" -ne 0 ]; then
        continue
      fi
      # is_ancestor, not a bare merge-base: rc 128 collapsed into "not reachable"
      # demotes the true branch point, and the walk settles on an older commit, so
      # the new release line is created behind where OSS actually is and re-replays
      # commits it already holds -- with nothing in the log saying git ever failed.
      anc_rc=0
      is_ancestor "$imported_full" "$DEFAULT_TIP" || anc_rc=$?
      if [ "$anc_rc" -eq 2 ]; then
        rm -f "$exported_map"
        die "git failed testing whether ${imported_full} is on OSS ${OSS_DEFAULT_BRANCH}; refusing to anchor a new OSS branch"
      elif [ "$anc_rc" -ne 0 ]; then
        continue
      fi
      if [ -z "$imported_best" ]; then
        imported_best="$imported_full"
        continue
      fi
      anc_rc=0
      is_ancestor "$imported_best" "$imported_full" || anc_rc=$?
      if [ "$anc_rc" -eq 2 ]; then
        rm -f "$exported_map"
        die "git failed comparing ${OSS_TRAILER} records on ${m}; refusing to anchor a new OSS branch"
      elif [ "$anc_rc" -eq 0 ]; then
        imported_best="$imported_full"
      fi
    done <<< "$imported_values"
    if [ -n "$imported_best" ]; then
      RESUME="$m"
      OSS_TIP="$imported_best"
      break
    fi
  done <<< "$branch_walk"
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
# Captured first, like the divergence guard's walk: a producer that fails inside
# `done < <(...)` is invisible to set -e, so a broken rev-list replays nothing and
# the run reports a clean, empty export. With align-tree it then pushes a snapshot
# built from a range nobody managed to list.
if ! replay_range="$(git rev-list --reverse --first-parent "${RESUME}..HEAD" -- "$SUBTREE_PREFIX")"; then
  die "failed to list the replay range ${RESUME}..HEAD; refusing to export"
fi
while read -r M; do
  [ -n "$M" ] || continue
  ensure_not_merge "$M"
  ht_rc=0
  has_trailer "$M" "$OSS_TRAILER" || ht_rc=$?
  if [ "$ht_rc" -eq 2 ]; then
    die "git failed reading the ${OSS_TRAILER} trailer of ${M}; refusing to decide whether it originated on OSS"
  elif [ "$ht_rc" -eq 0 ]; then
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
done <<< "$replay_range"

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
      loose_absorption_recovery
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
    if [ "${#loose_absorbed[@]}" -gt 0 ]; then
      # NOT "re-run with align-tree": the gate above refuses exactly that while
      # these commits are absorbed only outside git's trailer block, so the
      # obvious next step is a round trip that cannot terminate. The operator has
      # to decide per commit either way, so say that here rather than one failure
      # later.
      echo "::error::Do not re-run with align-tree: these external commits are absorbed only by an ${OSS_TRAILER} line outside git's trailer block, which is enough to keep exporting and not enough to delete their content, so align-tree refuses the run rather than fixing it:"
      printf '::error::  %s\n' "${loose_absorbed[@]}"
      echo "::error::Decide per commit first:"
      loose_absorption_recovery
    else
      echo "::error::Re-run with align-tree=true to append a snapshot alignment commit."
    fi
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

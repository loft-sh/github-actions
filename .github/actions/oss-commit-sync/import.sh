#!/usr/bin/env bash
set -euo pipefail

# Import external OSS commits into the monorepo subtree on a PR branch.
#
# Every first-parent OSS commit after the resume point that we did not create
# (no "Monorepo-Commit:" trailer) is replayed under SUBTREE_PREFIX as its own
# commit: the commit's diff (minus EXCLUDE_PATHS) is 3-way applied with
# --directory, preserving author, date, and message, plus an
# "Oss-Commit: <sha>" trailer. The caller pushes the PR branch and opens or
# updates the sync PR; the PR must be rebase-merged so per-commit history and
# trailers survive on the base branch.
#
# Resume point: the recorded Oss-Commit trailer that reaches farthest along OSS
# history (see import_resume_point). SEED_OSS_COMMIT acts as a floor on it, so
# an operator can re-anchor a sync whose trailer state was damaged without
# rewriting history. Commits whose diff is empty after path exclusion (touched
# only excluded producer workflows) are skipped without a marker commit: the
# skip decision is deterministic from the commit itself, so re-walking them on
# the next run is idempotent and free. This deliberately avoids --allow-empty
# marker commits, whose survival across GitHub's rebase-merge is not guaranteed.
#
# Before walking anything, the subtree is compared against the OSS tip: when it
# already holds the tip content there is provably nothing to import and the run
# exits green without replaying. That is the backstop for a stale anchor, which
# would otherwise re-walk commits already in the subtree and hard-fail as soon
# as one of them stopped applying as a no-op, a later OSS commit having since
# touched the same lines.
#
# Diff replay (not tree snapshots) means an external commit never reverts
# monorepo changes that have not been exported yet: only the external
# commit's own changes are applied. A genuine overlap fails the 3-way apply
# loudly and cleanly.
#
# The repository MUST be checked out at the base branch (BRANCH) when this
# script runs: the PR branch is rebuilt from HEAD, and the resume point is
# read from HEAD's history.
#
# Required env: SUBTREE_PREFIX, OSS_REMOTE, BRANCH.
# Optional env: SEED_OSS_COMMIT (first run, when the base branch has no
# Oss-Commit trailer yet; also a floor on a recorded anchor),
# EXCLUDE_PATHS (newline-separated paths relative to the OSS repo root),
# PR_BRANCH (default automation/sync-from-oss-<branch>), GITHUB_OUTPUT.
#
# Outputs: has-changes, replayed-count, skipped-count, conflict-sha,
# pr-branch.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBTREE_PREFIX="${SUBTREE_PREFIX:?SUBTREE_PREFIX is required}"
OSS_REMOTE="${OSS_REMOTE:?OSS_REMOTE is required}"
BRANCH="${BRANCH:?BRANCH is required}"
SEED_OSS_COMMIT="${SEED_OSS_COMMIT:-}"
EXCLUDE_PATHS="${EXCLUDE_PATHS:-}"
PR_BRANCH="${PR_BRANCH:-automation/sync-from-oss-${BRANCH}}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

cd "$(git rev-parse --show-toplevel)"

emit has-changes false
emit replayed-count 0
emit skipped-count 0
emit conflict-sha ""
emit pr-branch "$PR_BRANCH"

git_scrubbed fetch --quiet "$OSS_REMOTE" "refs/heads/${BRANCH}" \
  || die "failed to fetch OSS branch ${BRANCH}"
OSS_TIP="$(git rev-parse FETCH_HEAD)"

# --- build exclude pathspecs ------------------------------------------------

build_excludes

# --- resume point ------------------------------------------------------------

RESUME="$(import_resume_point "$OSS_TIP")"

# SEED_OSS_COMMIT is a floor, not just a first-run fallback: re-anchoring a
# damaged sync must not require rewriting history on the base branch.
if [ -n "$SEED_OSS_COMMIT" ] && git cat-file -e "${SEED_OSS_COMMIT}^{commit}" 2>/dev/null; then
  if [ -z "$RESUME" ] || git merge-base --is-ancestor "$RESUME" "$SEED_OSS_COMMIT"; then
    RESUME="$SEED_OSS_COMMIT"
  fi
fi

# --- nothing-to-import fast path ---------------------------------------------

# Convergence is a statement about content, so it holds regardless of what the
# trailer state says, which makes it the one check a damaged anchor cannot
# defeat. Deliberately evaluated before the anchor is *required*: with the
# subtree already at the OSS tip there is nothing a replay could add, so a
# broken anchor must not turn "nothing to do" into a red pipeline.
if subtree_converged "$OSS_TIP"; then
  # Report the collapsed range rather than a bare 0, so a stale anchor shows up
  # as work being skipped every run instead of looking like a quiet no-op.
  if [ -n "$RESUME" ]; then
    emit skipped-count "$(git rev-list --count --first-parent "${RESUME}..${OSS_TIP}")"
  fi
  echo "${SUBTREE_PREFIX} already holds OSS ${BRANCH} at ${OSS_TIP}; nothing to import"
  exit 0
fi

if [ -z "$RESUME" ]; then
  if [ "$resume_saw_candidate" = "true" ]; then
    die "no ${OSS_TRAILER} trailer on ${BRANCH} points at a commit reachable from OSS ${BRANCH} tip; history may have been rewritten on OSS"
  fi
  die "no ${OSS_TRAILER} trailer found on ${BRANCH} and no SEED_OSS_COMMIT provided for the first run"
fi

git cat-file -e "${RESUME}^{commit}" \
  || die "resume point ${RESUME} is not a commit (bad trailer or seed?)"
git merge-base --is-ancestor "$RESUME" "$OSS_TIP" \
  || die "resume point ${RESUME} is not an ancestor of OSS ${BRANCH} tip; history may have been rewritten on OSS"

# --- replay onto a fresh PR branch -------------------------------------------

# The PR branch is rebuilt from the base tip every run: re-replaying the same
# range yields the same content, and the caller's force-push updates any open
# sync PR in place.
git switch --quiet -C "$PR_BRANCH"

replayed=0
skipped=0
while read -r E; do
  [ -n "$E" ] || continue
  ensure_not_merge "$E"
  if has_trailer "$E" "$MONOREPO_TRAILER"; then
    echo "Skipping ${E} (originated in the monorepo: $(trailer_value "$E" "$MONOREPO_TRAILER"))"
    continue
  fi
  patch="$(git diff-tree --no-commit-id -p --binary -M "$E" -- . ${excludes[@]+"${excludes[@]}"})"
  if [ -z "$patch" ]; then
    skipped=$((skipped + 1))
    echo "Skipping ${E} (touches only excluded paths)"
    continue
  fi
  # Checked before applying, not after: a commit whose post-image is already in
  # the subtree contributes nothing, and replaying it can only produce a no-op
  # or a spurious conflict with a LATER change that is also already present. A
  # stale anchor therefore degrades to skipped work instead of a red pipeline.
  if external_is_benign "$E"; then
    skipped=$((skipped + 1))
    echo "Skipping ${E} (content already in ${SUBTREE_PREFIX})"
    continue
  fi
  if ! printf '%s\n' "$patch" | git apply --3way --directory="$SUBTREE_PREFIX" --whitespace=nowarn; then
    git reset --hard --quiet
    git clean -fdq -- "$SUBTREE_PREFIX"
    emit conflict-sha "$E"
    die "conflict replaying OSS commit ${E} into ${SUBTREE_PREFIX}; resolve manually (export any pending monorepo changes first, then re-run). If ${E} is in fact already present under a different shape, re-anchor with seed-oss-commit instead of resolving by hand."
  fi
  git add -A -- "$SUBTREE_PREFIX"
  # A non-empty patch can still apply as a no-op when the same change already
  # landed in staging (e.g. cherry-picked on both sides). Skip it instead of
  # letting `git commit` abort the run. No trailer is recorded; the export
  # divergence guard independently classifies such commits as benign because
  # their post-image is already present in the subtree.
  if nothing_staged "."; then
    skipped=$((skipped + 1))
    echo "Skipping ${E} (applies as a no-op; content already in ${SUBTREE_PREFIX})"
    continue
  fi
  replay_commit "$E" "$OSS_TRAILER" "."
  replayed=$((replayed + 1))
  echo "Replayed ${E} -> $(git rev-parse HEAD) ($(git log -1 --format=%s "$E"))"
done < <(git rev-list --reverse --first-parent "${RESUME}..${OSS_TIP}")

emit replayed-count "$replayed"
emit skipped-count "$skipped"
if [ "$replayed" -gt 0 ]; then
  emit has-changes true
  echo "Replayed ${replayed} external commit(s) onto ${PR_BRANCH} (${skipped} skipped)"
else
  echo "No external commits to import (${skipped} skipped)"
fi

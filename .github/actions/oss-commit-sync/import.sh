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
# Resume point: the newest Oss-Commit trailer on the base branch. Commits
# whose diff is empty after path exclusion (touched only excluded producer
# workflows) are skipped without a marker commit: the skip decision is
# deterministic from the commit itself, so re-walking them on the next run is
# idempotent and free. This deliberately avoids --allow-empty marker commits,
# whose survival across GitHub's rebase-merge is not guaranteed.
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
# Oss-Commit trailer yet), EXCLUDE_PATHS (newline-separated paths relative to
# the OSS repo root), PR_BRANCH (default automation/sync-from-oss-<branch>),
# GITHUB_OUTPUT.
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

# --- resume point ------------------------------------------------------------

entry="$(newest_trailer_entry HEAD "$OSS_TRAILER")"
if [ -n "$entry" ]; then
  RESUME="${entry#* }"
elif [ -n "$SEED_OSS_COMMIT" ]; then
  RESUME="$SEED_OSS_COMMIT"
else
  die "no ${OSS_TRAILER} trailer found on ${BRANCH} and no SEED_OSS_COMMIT provided for the first run"
fi

git cat-file -e "${RESUME}^{commit}" \
  || die "resume point ${RESUME} is not a commit (bad trailer or seed?)"
git merge-base --is-ancestor "$RESUME" "$OSS_TIP" \
  || die "resume point ${RESUME} is not an ancestor of OSS ${BRANCH} tip; history may have been rewritten on OSS"

# --- build exclude pathspecs ------------------------------------------------

excludes=()
while IFS= read -r p; do
  [ -n "$p" ] && excludes+=(":(exclude)${p}")
done <<< "$EXCLUDE_PATHS"

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
  if ! printf '%s\n' "$patch" | git apply --3way --directory="$SUBTREE_PREFIX" --whitespace=nowarn; then
    git reset --hard --quiet
    git clean -fdq -- "$SUBTREE_PREFIX"
    emit conflict-sha "$E"
    die "conflict replaying OSS commit ${E} into ${SUBTREE_PREFIX}; resolve manually (export any pending monorepo changes first, then re-run)"
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

#!/usr/bin/env bash
set -euo pipefail

# Report the health of the sync state between the monorepo subtree and OSS.
#
# Read-only: this direction never commits, pushes, or opens anything. It answers
# three questions a green export/import run does not:
#
#   1. Is the import anchor stale? A stale anchor makes every import re-walk OSS
#      commits already present in the subtree. That is invisible while each one
#      still applies as a no-op, and turns into a hard conflict the moment a
#      later OSS commit touches the same lines. Reported with the exact
#      seed-oss-commit value that re-anchors the sync.
#
#   2. Was a sync PR squash-merged? GitHub's squash appends "Co-authored-by:" as
#      a new paragraph, which orphans our trailer from the block git's own
#      %(trailers) parser reads. The trailer helpers here scan the whole message
#      so this no longer breaks the sync, but it does mean the merge policy was
#      violated and per-commit authorship of external contributions was lost on
#      the base branch, which is worth knowing.
#
#   3. How many OSS commits are genuinely waiting to be imported?
#
# Runs on push to the base branch: the answer only changes when the base branch
# or OSS moves.
#
# Required env: SUBTREE_PREFIX, OSS_REMOTE, BRANCH.
# Optional env: EXCLUDE_PATHS, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
#
# Outputs: converged, anchor, stale-anchor, suggested-anchor, pending-count,
# redundant-count, squashed-trailer-count.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBTREE_PREFIX="${SUBTREE_PREFIX:?SUBTREE_PREFIX is required}"
OSS_REMOTE="${OSS_REMOTE:?OSS_REMOTE is required}"
BRANCH="${BRANCH:?BRANCH is required}"
EXCLUDE_PATHS="${EXCLUDE_PATHS:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

cd "$(git rev-parse --show-toplevel)"

emit converged false
emit anchor ""
emit stale-anchor false
emit suggested-anchor ""
emit pending-count 0
emit redundant-count 0
emit squashed-trailer-count 0

git_scrubbed fetch --quiet "$OSS_REMOTE" "refs/heads/${BRANCH}" \
  || die "failed to fetch OSS branch ${BRANCH}"
OSS_TIP="$(git rev-parse FETCH_HEAD)"

build_excludes

converged=false
if subtree_converged "$OSS_TIP"; then
  converged=true
fi
emit converged "$converged"

ANCHOR="$(import_resume_point "$OSS_TIP")"
emit anchor "$ANCHOR"

# --- classify the un-anchored range -----------------------------------------

# A commit in ANCHOR..OSS_TIP is "redundant" when importing it cannot change the
# subtree: we created it (Monorepo-Commit trailer), it touches only excluded
# paths, or its post-image is already present. Anything else is pending.
pending=0
redundant=0
suggested=""
still_prefix=true
first_pending=""

if [ -n "$ANCHOR" ]; then
  while read -r E; do
    [ -n "$E" ] || continue
    is_redundant=false
    if has_trailer "$E" "$MONOREPO_TRAILER"; then
      is_redundant=true
    elif [ -z "$(git diff-tree --no-commit-id --name-only -r "$E" -- . ${excludes[@]+"${excludes[@]}"})" ]; then
      is_redundant=true
    elif external_is_benign "$E"; then
      is_redundant=true
    fi

    if [ "$is_redundant" = "true" ]; then
      redundant=$((redundant + 1))
      # Only a LEADING run of redundant commits can be collapsed into the
      # anchor: the anchor is a single point in OSS history, so advancing it
      # past a pending commit would silently drop that commit from the import.
      [ "$still_prefix" = "true" ] && suggested="$E"
    else
      pending=$((pending + 1))
      still_prefix=false
      [ -z "$first_pending" ] && first_pending="$E"
    fi
  done < <(git rev-list --reverse --first-parent "${ANCHOR}..${OSS_TIP}")
fi

emit pending-count "$pending"
emit redundant-count "$redundant"

stale=false
if [ -n "$suggested" ]; then
  stale=true
  emit suggested-anchor "$suggested"
fi
emit stale-anchor "$stale"

# --- detect squash-orphaned trailers ----------------------------------------

# A commit where our whole-message scan finds the trailer but git's own trailer
# block does not is the fingerprint of a squash-merged sync PR.
squashed=0
squashed_list=()
if [ -n "$ANCHOR" ]; then
  while read -r M value; do
    [ -n "$value" ] || continue
    if [ -z "$(git log -1 --format="%(trailers:key=${OSS_TRAILER},valueonly)" "$M" | tr -d '[:space:]')" ]; then
      squashed=$((squashed + 1))
      squashed_list+=("$M")
    fi
  done < <(all_trailer_entries HEAD "$OSS_TRAILER")
fi
emit squashed-trailer-count "$squashed"

# --- report ------------------------------------------------------------------

{
  echo "### OSS sync health: \`${SUBTREE_PREFIX}\` <-> ${BRANCH}"
  echo
  echo "| Check | Value |"
  echo "| --- | --- |"
  echo "| OSS tip | \`${OSS_TIP}\` |"
  echo "| Subtree matches OSS tip | ${converged} |"
  echo "| Import anchor | \`${ANCHOR:-none}\` |"
  echo "| Commits pending import | ${pending} |"
  echo "| Commits re-walked needlessly | ${redundant} |"
  echo "| Squash-orphaned trailers | ${squashed} |"
} >> "$GITHUB_STEP_SUMMARY"

if [ -z "$ANCHOR" ]; then
  echo "::warning::No readable ${OSS_TRAILER} trailer on ${BRANCH} points at a commit reachable from OSS ${BRANCH}. The import direction cannot resume without seed-oss-commit."
fi

if [ "$squashed" -gt 0 ]; then
  echo "::warning::${squashed} sync commit(s) on ${BRANCH} carry an ${OSS_TRAILER} trailer that GitHub's squash-merge orphaned from the trailer block. The sync reads it anyway, but per-commit authorship of the external contributions was collapsed on ${BRANCH}. Merge sync PRs with \"Rebase and merge\"."
  printf '::warning::  squash-merged: %s\n' "${squashed_list[@]}"
fi

if [ "$stale" = "true" ]; then
  {
    echo
    echo "The import anchor is behind OSS by ${redundant} commit(s) that are already"
    echo "present in \`${SUBTREE_PREFIX}\`. Every import re-walks them, which stays"
    echo "invisible only while each still applies as a no-op."
    echo
    echo "Re-anchor by running the sync-from-oss workflow with:"
    echo
    echo '```'
    echo "seed-oss-commit: ${suggested}"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
  echo "::warning::Import anchor ${ANCHOR} is stale; ${redundant} already-present OSS commit(s) are re-walked on every run. Re-anchor with seed-oss-commit: ${suggested}"
fi

if [ -n "$first_pending" ]; then
  echo "Oldest OSS commit pending import: ${first_pending}"
fi

echo "Health: converged=${converged} anchor=${ANCHOR:-none} pending=${pending} redundant=${redundant} squash-orphaned=${squashed}"

#!/usr/bin/env bash
set -euo pipefail

# Report the health of the sync state between the monorepo subtree and OSS.
#
# Read-only: this direction never commits, pushes, or opens anything, and never
# fails the caller. It exists for hygiene, not for outages — the import heals its
# own anchor from content, so none of what is reported here is a broken pipeline
# waiting to happen. What it surfaces is the drift a green run hides:
#
#   1. Do the recorded trailers still match reality? The import derives its
#      anchor from the subtree content when the trailers lag, so a lag is
#      harmless to the sync but means those external commits carry no recorded
#      provenance on the base branch, and that trailers are being lost somewhere.
#
#   2. Was a sync PR squash-merged? GitHub's squash appends "Co-authored-by:" as
#      a new paragraph, which orphans our trailer from the block git's own
#      %(trailers) parser reads. The trailer helpers scan the whole message so
#      this no longer breaks the sync, but the merge policy was violated and
#      per-commit authorship of external contributions was collapsed.
#
#   3. How many OSS commits are genuinely waiting to be imported?
#
# Runs on push to the base branch: the answer only changes when the base branch
# or OSS moves.
#
# Required env: SUBTREE_PREFIX, OSS_REMOTE, BRANCH.
# Optional env: EXCLUDE_PATHS, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
#
# Outputs: converged, anchor, recorded-anchor, stale-anchor, suggested-anchor,
# pending-count, redundant-count, squashed-trailer-count, degraded.
#
# Never exits non-zero: an advisory check must not red the caller's job. When a
# git or network step fails it warns, sets degraded=true, and returns 0 with
# whatever it could determine.

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
emit recorded-anchor ""
emit stale-anchor false
emit suggested-anchor ""
emit pending-count 0
emit redundant-count 0
emit squashed-trailer-count 0
emit degraded false

# An advisory check must not red the caller's job. A transient network failure,
# an expired token, or a renamed OSS branch degrades to a warning: we would
# rather lose one report than block a push to the base branch.
if ! git_scrubbed fetch --quiet "$OSS_REMOTE" "refs/heads/${BRANCH}"; then
  echo "::warning::Could not fetch OSS branch ${BRANCH}; skipping the sync health report."
  exit 0
fi
# Guarded like everything else here: an unguarded assignment would trip `set -e`
# and exit non-zero, breaking the never-fail contract this script documents.
if ! OSS_TIP="$(git rev-parse FETCH_HEAD)"; then
  echo "::warning::Could not resolve FETCH_HEAD after fetching OSS ${BRANCH}; skipping the sync health report."
  exit 0
fi

build_excludes

converged=false
if subtree_matches "$OSS_TIP"; then
  converged=true
fi
emit converged "$converged"

# The same resolution the import performs, seed floor and healing included, so
# the two directions cannot disagree about where the sync stands. That matters
# most in the damaged-state cases this report exists to diagnose.
degraded=false
if ! resolve_import_anchor "$OSS_TIP"; then
  degraded=true
  echo "::warning::Could not resolve the import anchor (git error); the anchor figures below are incomplete."
fi
ANCHOR="$IMPORT_ANCHOR"
RECORDED="$IMPORT_ANCHOR_RECORDED"
emit anchor "$ANCHOR"
emit recorded-anchor "$RECORDED"

if [ "$IMPORT_ANCHOR_SEED_BAD" = "true" ]; then
  echo "::warning::SEED_OSS_COMMIT ${SEED_OSS_COMMIT} is not a commit reachable from OSS ${BRANCH} tip; the import would reject it."
fi

# --- how far the recorded trailers lag behind the content -------------------

# The import heals this gap itself on every run, so it is a hygiene signal, not
# an outage: trailers are being lost somewhere (a squash, a hand-edited message,
# a hand-made import), and until that stops, each run re-derives the anchor and
# the affected external commits carry no recorded provenance.
redundant="$IMPORT_ANCHOR_HEALED"
stale=false
if [ "$redundant" -gt 0 ]; then
  stale=true
  emit suggested-anchor "$ANCHOR"
fi
emit redundant-count "$redundant"
emit stale-anchor "$stale"

# --- genuinely pending externals --------------------------------------------

# Counted from the healed anchor: a commit still needs importing unless we
# created it (Monorepo-Commit trailer), it touches only excluded paths, or its
# post-image is already in the subtree.
pending=0
first_pending=""
if [ -n "$ANCHOR" ]; then
  # Captured, not piped from a process substitution: `set -e` cannot see a
  # producer failure inside `done < <(...)`, so the loop would run zero times and
  # this check would report a clean backlog because git broke. Reporting "clean"
  # on error is the one thing a health check must never do.
  if pending_shas="$(git rev-list --reverse --first-parent "${ANCHOR}..${OSS_TIP}")"; then
    while read -r E; do
      [ -n "$E" ] || continue
      has_trailer "$E" "$MONOREPO_TRAILER" && continue
      # Captured for the same reason as the outer rev-list: an unguarded failure
      # here yields empty output, which reads as "touches only excluded paths"
      # and drops the commit from the backlog with no degraded signal.
      if ! diff_files="$(git diff-tree --no-commit-id --name-only -r "$E" -- . ${excludes[@]+"${excludes[@]}"})"; then
        degraded=true
        echo "::warning::Could not diff OSS commit ${E}; pending-count may be understated."
        continue
      fi
      [ -z "$diff_files" ] && continue
      external_is_benign "$E" && continue
      pending=$((pending + 1))
      [ -z "$first_pending" ] && first_pending="$E"
    done <<< "$pending_shas"
  else
    degraded=true
    echo "::warning::Could not list OSS commits in ${ANCHOR}..${OSS_TIP}; pending-count is not reliable in this run."
  fi
fi
emit pending-count "$pending"

# --- detect squash-orphaned trailers ----------------------------------------

# A commit where our whole-message scan finds the trailer but git's own trailer
# block does not is the fingerprint of a squash-merged sync PR.
squashed=0
squashed_list=()
# Same capture-first reason as the pending loop: a broken producer must not read
# as "no policy violations".
if entries="$(all_trailer_entries HEAD "$OSS_TRAILER")"; then
  while read -r M value; do
    [ -n "$value" ] || continue
    # Guarded in the other direction from the pending loop: an unguarded failure
    # yields empty output, which here reads as "git could not see the trailer",
    # i.e. a squash, and would raise a false policy alarm against a clean commit.
    if ! parsed="$(git log -1 --format="%(trailers:key=${OSS_TRAILER},valueonly)" "$M")"; then
      degraded=true
      echo "::warning::Could not read the trailer block of ${M}; squashed-trailer-count may be understated."
      continue
    fi
    if [ -z "$(printf '%s' "$parsed" | tr -d '[:space:]')" ]; then
      squashed=$((squashed + 1))
      squashed_list+=("$M")
    fi
  done <<< "$entries"
else
  degraded=true
  echo "::warning::Could not read ${OSS_TRAILER} trailers from ${BRANCH}; squashed-trailer-count is not reliable in this run."
fi
emit squashed-trailer-count "$squashed"
emit degraded "$degraded"

# --- report ------------------------------------------------------------------

{
  echo "### OSS sync health: \`${SUBTREE_PREFIX}\` <-> ${BRANCH}"
  echo
  echo "| Check | Value |"
  echo "| --- | --- |"
  echo "| OSS tip | \`${OSS_TIP}\` |"
  echo "| Subtree matches OSS tip | ${converged} |"
  echo "| Import anchor (after healing) | \`${ANCHOR:-none}\` |"
  echo "| Recorded by a trailer | \`${RECORDED:-none}\` |"
  echo "| Commits pending import | ${pending} |"
  echo "| Commits the anchor heals over | ${redundant} |"
  echo "| Squash-orphaned trailers | ${squashed} |"
} >> "$GITHUB_STEP_SUMMARY"

if [ -z "$ANCHOR" ]; then
  echo "::warning::No readable ${OSS_TRAILER} trailer on ${BRANCH} points at a commit reachable from OSS ${BRANCH}, and no subtree content matches an OSS commit. This is the one state the import cannot heal by itself; it needs seed-oss-commit."
fi

if [ "$squashed" -gt 0 ]; then
  echo "::warning::${squashed} sync commit(s) on ${BRANCH} carry an ${OSS_TRAILER} trailer that GitHub's squash-merge orphaned from the trailer block. The sync reads it anyway, but per-commit authorship of the external contributions was collapsed on ${BRANCH}. Merge sync PRs with \"Rebase and merge\"."
  printf '::warning::  squash-merged: %s\n' "${squashed_list[@]}"
fi

if [ "$stale" = "true" ]; then
  {
    echo
    echo "The recorded anchor lags the subtree by ${redundant} commit(s). The import"
    echo "heals this from content on every run, so nothing is broken and no repair"
    echo "is needed. It does mean those external commits carry no recorded"
    echo "provenance on \`${BRANCH}\`, which points at trailers being lost during"
    echo "merge: check the squash count above."
  } >> "$GITHUB_STEP_SUMMARY"
  echo "::notice::Recorded anchor ${RECORDED} lags content by ${redundant} commit(s); the import heals to ${ANCHOR} automatically. Provenance for those commits is not recorded on ${BRANCH}."
fi

if [ -n "$first_pending" ]; then
  echo "Oldest OSS commit pending import: ${first_pending}"
fi

echo "Health: converged=${converged} anchor=${ANCHOR:-none} pending=${pending} redundant=${redundant} squash-orphaned=${squashed}"

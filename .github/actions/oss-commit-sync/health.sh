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
#      Counted only over commits carrying neither trailer: the anchor also trails
#      our own exports (Monorepo-Commit, never Oss-Commit), which is the steady
#      state after every export rather than a sign of anything lost.
#
#   2. Was a sync PR squash-merged? GitHub's squash appends "Co-authored-by:" as
#      a new paragraph, which orphans our trailer from the block git's own
#      %(trailers) parser reads. Even without that paragraph, a squash of N
#      replayed commits leaves only the last of its N trailers in the block, so
#      the check compares the whole-message scan against the block as sets rather
#      than asking whether the block came back empty. The trailer helpers scan
#      the whole message so none of this breaks the sync, but the merge policy
#      was violated and per-commit authorship of external contributions was
#      collapsed.
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
# pending-count, redundant-count, redundant-export-count,
# redundant-unrecorded-count, squashed-trailer-count, degraded.
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
emit redundant-export-count 0
emit redundant-unrecorded-count 0
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
#
# Staleness is judged on the unrecorded commits alone. The healed range also
# holds our own exports, which carry Monorepo-Commit and by design never an
# Oss-Commit trailer, so the anchor trails every export until the next import
# records a trailer past it. Counting those as staleness would report a lag on a
# perfectly healthy sync, permanently, and bury the case that does need a look.
redundant="$IMPORT_ANCHOR_HEALED"
redundant_exports="$IMPORT_ANCHOR_HEALED_EXPORTS"
redundant_unrecorded="$IMPORT_ANCHOR_HEALED_UNRECORDED"
stale=false
if [ "$redundant_unrecorded" -gt 0 ]; then
  stale=true
  emit suggested-anchor "$ANCHOR"
fi
emit redundant-count "$redundant"
emit redundant-export-count "$redundant_exports"
emit redundant-unrecorded-count "$redundant_unrecorded"
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

# Counts commits carrying an Oss-Commit value that our whole-message scan finds
# and git's own trailer block does not. A squash produces that; so does a
# trailer-shaped line quoted in a commit body, and the two are locally
# indistinguishable. Requiring the value to name a commit in OSS history rules
# out fabricated and unrelated hex, not a real sha someone quoted, so read a
# non-zero count as a reason to look rather than as proof. What it misses is
# recorded below.
squashed=0
squashed_list=()
# One pass, walked in groups. trailer_scan emits every value in log order, so a
# commit's values arrive consecutively and the group boundary is just a change of
# sha. The previous shape (a second history walk, plus an awk over the whole scan
# per commit) was quadratic in a set that only grows, and the two walks could
# disagree about which commits exist if HEAD moved between them.
#
# Same capture-first reason as the pending loop: a broken producer must not read
# as "no policy violations".
if scanned_all="$(trailer_scan "$OSS_TRAILER" 1 --first-parent HEAD)"; then
  cur=""
  orphaned=false
  parsed_norm=""
  cur_usable=false
  while read -r M v; do
    [ -n "$v" ] || continue
    if [ "$M" != "$cur" ]; then
      # Close out the previous group before starting this one.
      if [ "$orphaned" = "true" ]; then
        squashed=$((squashed + 1))
        squashed_list+=("$cur")
      fi
      cur="$M"
      orphaned=false
      cur_usable=true
      # Guarded in the other direction from the pending loop: an unguarded
      # failure yields empty output, which here reads as "git could not see the
      # trailer", i.e. a squash, and would raise a false alarm against a clean
      # commit. The trailing-space strip mirrors what trailer_scan already does.
      # unfold, matching the export guard: without it a folded value stays several
      # physical lines and its first line would match a scanned sha here, scoring a
      # commit clean that the export treats as having no block record.
      if parsed="$(git log -1 --format="%(trailers:key=${OSS_TRAILER},valueonly,unfold)" "$M")"; then
        parsed_norm="$(printf '%s\n' "$parsed" | sed 's/[[:space:]]*$//')"
      else
        degraded=true
        cur_usable=false
        echo "::warning::Could not read the trailer block of ${M}; squashed-trailer-count may be understated."
      fi
    fi
    [ "$cur_usable" = "true" ] || continue
    # A set comparison, not "is git's block empty". A squash that appends no
    # Co-authored-by paragraph leaves the LAST trailer inside the block git
    # parses while every earlier one stays orphaned above it, so an emptiness
    # test scores that commit clean and misses the shape this check exists to
    # catch.
    #
    # A here-string, not printf into a pipe: grep -q exits at the first match and
    # would SIGPIPE the writer, which under pipefail reads as failure and would
    # flag a clean commit.
    grep -qxF "$v" <<< "$parsed_norm" && continue
    # The deliberate trade in the other direction: a real orphaned record whose
    # commit has left OSS history (force-push, recreated branch) or whose
    # abbreviation has since become ambiguous is NOT counted. Under-reporting
    # beats accusing a maintainer who merged correctly.
    res_rc=0
    v_full="$(resolve_commit_prefix "$v")" || res_rc=$?
    if [ "$res_rc" -eq 2 ]; then
      # Same reason the ancestry rc is split below: a git failure is not an
      # answer about the value, and counting it as one would let a broken
      # rev-parse hand back a clean bill of health.
      degraded=true
      echo "::warning::Could not resolve the ${OSS_TRAILER} value ${v} on ${M}; squashed-trailer-count may be understated."
      continue
    elif [ "$res_rc" -ne 0 ]; then
      continue
    fi
    # rc 1 is "not in OSS history"; anything else is git failing, and the two
    # must not collapse, or a broken merge-base reads as a clean bill of health.
    anc_rc=0
    git merge-base --is-ancestor "$v_full" "$OSS_TIP" 2>/dev/null || anc_rc=$?
    case "$anc_rc" in
      0) orphaned=true ;;
      1) ;;
      *)
        degraded=true
        echo "::warning::Could not test whether ${v_full} is in OSS ${BRANCH} history; squashed-trailer-count may be understated."
        ;;
    esac
  done <<< "$scanned_all"
  # The last group has no successor to close it.
  if [ "$orphaned" = "true" ]; then
    squashed=$((squashed + 1))
    squashed_list+=("$cur")
  fi
else
  degraded=true
  echo "::warning::Could not scan ${BRANCH} for ${OSS_TRAILER} lines; squashed-trailer-count is not reliable in this run."
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
  echo "| ... our own exports (expected) | ${redundant_exports} |"
  echo "| ... imports with no trailer | ${redundant_unrecorded} |"
  echo "| Squash-orphaned trailers | ${squashed} |"
} >> "$GITHUB_STEP_SUMMARY"

if [ -z "$ANCHOR" ]; then
  echo "::warning::No readable ${OSS_TRAILER} trailer on ${BRANCH} points at a commit reachable from OSS ${BRANCH}, and no subtree content matches an OSS commit. This is the one state the import cannot heal by itself; it needs seed-oss-commit."
fi

if [ "$squashed" -gt 0 ]; then
  # Hedged like the README and the output description: this is the shape a squash
  # leaves, and also the shape of a real trailer line quoted in a body. Telling a
  # maintainer flatly that they squashed is the one thing this must not get wrong.
  echo "::warning::${squashed} commit(s) on ${BRANCH} carry an ${OSS_TRAILER} value outside the block git's own trailer parser reads. GitHub's squash-merge does that, and if that is the cause then per-commit authorship of those external contributions was collapsed and cannot be recovered; merge sync PRs with \"Rebase and merge\". A real ${OSS_TRAILER} line quoted in a commit body looks identical here, so check the commits below before concluding."
  # Labelled by what was observed, not by the conclusion the line above declines
  # to draw for the reader.
  printf '::warning::  value outside the trailer block: %s\n' "${squashed_list[@]}"
fi

if [ "$stale" = "true" ]; then
  {
    echo
    echo "${redundant_unrecorded} external commit(s) are in the subtree with no trailer"
    echo "recording them. The import heals this from content on every run, so nothing"
    echo "is broken and no repair is needed. It does mean those commits carry no"
    echo "recorded provenance on \`${BRANCH}\`, which points at trailers being lost"
    echo "during merge: check the squash count above."
  } >> "$GITHUB_STEP_SUMMARY"
  echo "::notice::${redundant_unrecorded} external commit(s) are present in ${SUBTREE_PREFIX} with no readable ${OSS_TRAILER} trailer; the import heals the anchor from ${RECORDED} to ${ANCHOR} automatically, but provenance for those commits is not recorded on ${BRANCH}."
fi

if [ -n "$first_pending" ]; then
  echo "Oldest OSS commit pending import: ${first_pending}"
fi

echo "Health: converged=${converged} anchor=${ANCHOR:-none} pending=${pending} redundant=${redundant} (exports=${redundant_exports} unrecorded=${redundant_unrecorded}) squash-orphaned=${squashed}"

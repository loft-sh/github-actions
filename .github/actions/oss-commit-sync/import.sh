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
# history (see resolve_import_anchor). SEED_OSS_COMMIT acts as a floor on it, so
# an operator can re-anchor a sync whose trailer state was damaged without
# rewriting history. Commits whose diff is empty after path exclusion (touched
# only excluded producer workflows) are skipped without a marker commit: the
# skip decision is deterministic from the commit itself, so re-walking them on
# the next run is idempotent and free. This deliberately avoids --allow-empty
# marker commits, whose survival across GitHub's rebase-merge is not guaranteed.
#
# The anchor then heals itself from content: it advances to the newest OSS commit
# whose content the subtree already holds. A trailer is a *record* of an import,
# but the subtree tree is *evidence* of one, and evidence survives a squash, a
# hand-edited message, or a hand-made import that forgot the trailer. Damaged
# trailer state therefore repairs itself on every run, with no marker commit and
# no operator action. Without it the redundant range is re-walked every run,
# which is invisible while each commit still applies as a no-op and then becomes
# a hard conflict once a later OSS commit touches the same lines as an earlier
# one. Commits after the healed anchor are still imported normally, so nothing is
# skipped silently. Most of what it heals over is our own exports, which carry
# Monorepo-Commit and by design never an Oss-Commit trailer, so the counts are
# reported split: only commits with neither trailer mean a record was lost.
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
# Outputs: has-changes, replayed-count, skipped-count, healed-count,
# healed-export-count, healed-unrecorded-count, conflict-sha, pr-branch.

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
emit healed-count 0
emit healed-export-count 0
emit healed-unrecorded-count 0
emit conflict-sha ""
emit pr-branch "$PR_BRANCH"

git_scrubbed fetch --quiet "$OSS_REMOTE" "refs/heads/${BRANCH}" \
  || die "failed to fetch OSS branch ${BRANCH}"
OSS_TIP="$(git rev-parse FETCH_HEAD)"

# --- build exclude pathspecs ------------------------------------------------

build_excludes

# --- resume point ------------------------------------------------------------

# Called plainly, never in a command substitution: the results come back in
# globals, which a subshell would discard. Fails closed on a git error rather
# than resuming from a half-resolved anchor.
resolve_import_anchor "$OSS_TIP" \
  || die "failed to resolve the import anchor for OSS ${BRANCH} (git error); refusing to import from an unknown point"
RESUME="$IMPORT_ANCHOR"
healed="$IMPORT_ANCHOR_HEALED"
healed_exports="$IMPORT_ANCHOR_HEALED_EXPORTS"
healed_unrecorded="$IMPORT_ANCHOR_HEALED_UNRECORDED"

if [ "$IMPORT_ANCHOR_SEED_BAD" = "true" ]; then
  die "SEED_OSS_COMMIT ${SEED_OSS_COMMIT} is not a commit reachable from OSS ${BRANCH} tip"
fi

if [ -z "$RESUME" ]; then
  if [ "$IMPORT_ANCHOR_SAW_TRAILER" = "true" ]; then
    die "no ${OSS_TRAILER} trailer on ${BRANCH} points at a commit reachable from OSS ${BRANCH} tip; history may have been rewritten on OSS"
  fi
  die "no ${OSS_TRAILER} trailer found on ${BRANCH} and no SEED_OSS_COMMIT provided for the first run"
fi

# Only unrecorded commits are a finding. Healing over our own exports is the
# steady state of a healthy sync: an OSS commit we created carries
# Monorepo-Commit and never an Oss-Commit trailer, so the anchor trails every
# export until the next import records a trailer past it. Annotating that as
# "not recorded by a readable trailer" reads as trailer damage on a run where
# nothing is wrong, and it fires after every single export.
if [ "$healed_unrecorded" -gt 0 ]; then
  echo "::notice::Anchor healed from content: ${IMPORT_ANCHOR_RECORDED:-none} -> ${RESUME} (${healed_unrecorded} OSS commit(s) already present in ${SUBTREE_PREFIX} that no readable ${OSS_TRAILER} trailer records, plus ${healed_exports} of our own export(s)). Those imports lost their provenance record: check the merge method on the sync PRs."
elif [ "$healed" -gt 0 ]; then
  echo "Anchor advanced ${IMPORT_ANCHOR_RECORDED:-none} -> ${RESUME} over ${healed} of our own export(s), whose content ${SUBTREE_PREFIX} already holds. Expected after every export; nothing to do."
fi
emit healed-count "$healed"
emit healed-export-count "$healed_exports"
emit healed-unrecorded-count "$healed_unrecorded"

if [ "$RESUME" = "$OSS_TIP" ]; then
  emit skipped-count "$healed"
  echo "${SUBTREE_PREFIX} already holds OSS ${BRANCH} at ${OSS_TIP}; nothing to import"
  exit 0
fi

# --- replay onto a fresh PR branch -------------------------------------------

# The PR branch is rebuilt from the base tip every run: re-replaying the same
# range yields the same content, and the caller's force-push updates any open
# sync PR in place.
git switch --quiet -C "$PR_BRANCH"

replayed=0
# Seeded with the healed range: those commits were considered and not replayed,
# which is exactly what skipped-count reports.
skipped="$healed"
# Captured first: a producer that fails inside `done < <(...)` is invisible to
# set -e, so a broken rev-list would replay nothing and the run would report
# has-changes=false with commits still waiting to be imported.
if ! replay_range="$(git rev-list --reverse --first-parent "${RESUME}..${OSS_TIP}")"; then
  die "failed to list the replay range ${RESUME}..${OSS_TIP}; refusing to import"
fi
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
done <<< "$replay_range"

emit replayed-count "$replayed"
emit skipped-count "$skipped"
if [ "$replayed" -gt 0 ]; then
  emit has-changes true
  echo "Replayed ${replayed} external commit(s) onto ${PR_BRANCH} (${skipped} skipped)"
else
  echo "No external commits to import (${skipped} skipped)"
fi

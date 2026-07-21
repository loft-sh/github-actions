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
# Outputs: pushed, diverged, exported-count, oss-tip.

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

excludes=()
while IFS= read -r p; do
  [ -n "$p" ] && excludes+=(":(exclude)${p}")
done <<< "$EXCLUDE_PATHS"

# external_is_benign <oss-sha>
# True when the commit's post-image (minus EXCLUDE_PATHS) is already present
# in the subtree, so mirroring on top of it cannot lose content. Covers the
# two externals the import direction deliberately skips without a trailer:
# excluded-paths-only commits, and changes that landed identically on both
# sides (import applied them as a no-op). Renames are inspected without -M so
# they decompose into delete+add and get checked path by path. A false
# "benign" cannot corrupt the mirror: the convergence assertion still fails
# the run before pushing if OSS actually holds content the subtree lacks.
external_is_benign() {
  local s="$1" status path blob_oss blob_staging
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    if [ "$status" = "D" ]; then
      # Deletion is benign only if the path is gone from staging too.
      if git cat-file -e "HEAD:${SUBTREE_PREFIX}/${path}" 2>/dev/null; then
        return 1
      fi
      continue
    fi
    blob_oss="$(git rev-parse --quiet --verify "${s}:${path}" 2>/dev/null)" || return 1
    blob_staging="$(git rev-parse --quiet --verify "HEAD:${SUBTREE_PREFIX}/${path}" 2>/dev/null)" || return 1
    [ "$blob_oss" = "$blob_staging" ] || return 1
  done < <(git diff-tree --no-commit-id --name-status -r "$s" -- . ${excludes[@]+"${excludes[@]}"})
  return 0
}

emit diverged false
emit pushed false
emit exported-count 0

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
  absorbed_file="$(mktemp)"
  all_trailer_entries "${RESUME}..HEAD" "$OSS_TRAILER" | awk '{print $2}' > "$absorbed_file"
  unabsorbed=()
  for s in $(git rev-list --first-parent "${OSS_ANCHOR}..${OSS_TIP}"); do
    has_trailer "$s" "$MONOREPO_TRAILER" && continue
    grep -qxF "$s" "$absorbed_file" && continue
    if external_is_benign "$s"; then
      echo "External ${s} is benign (excluded paths only, or content already in ${SUBTREE_PREFIX})"
      continue
    fi
    unabsorbed+=("$s")
  done
  rm -f "$absorbed_file"
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
    echo "Skipping ${M} (originated on OSS: $(trailer_value "$M" "$OSS_TRAILER"))"
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
  git_scrubbed push --quiet "$OSS_REMOTE" "${NEW_TIP}:refs/heads/${BRANCH}"
  emit pushed true
  echo "Pushed ${NEW_TIP} to OSS ${BRANCH}"
else
  echo "Nothing to push; OSS ${BRANCH} is up to date"
fi
emit exported-count "$count"
emit oss-tip "$NEW_TIP"

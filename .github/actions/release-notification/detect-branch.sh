#!/usr/bin/env bash
# detect-branch.sh — Name the branch a release tag was cut from.
#
# Resolution order, first match wins:
#   1. BASE_BRANCH, the caller's answer, when the tag commit is on it. It is
#      also trusted when it cannot be checked (no checkout, tag not fetched,
#      branch deleted after the cut), since the caller picked it.
#   2. The default branch and the version's release line (release-X.Y or
#      vX.Y), when they contain the tag commit. A stable version checks its
#      line first, since stables are only cut there; a prerelease checks the
#      default branch first, since a line branched after an alpha also holds it.
#   3. The remote branch containing the tag commit whose tip is closest. This
#      is a guess, and only reached for tags cut from feature branches.
#
# Required environment variables:
#   RELEASE_VERSION  — the release tag (e.g. v1.2.3)
#
# Optional environment variables:
#   BASE_BRANCH      — the branch the caller says the tag was cut from
#   DEFAULT_BRANCH   — fallback branch name (default: main)
#
# Output (stdout): the detected branch name

set -euo pipefail

: "${RELEASE_VERSION:?RELEASE_VERSION must be set}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
BASE_BRANCH="${BASE_BRANCH:-}"

# The name is quoted into the Slack payload's YAML and into log annotations,
# so only plain branch characters get through.
valid_branch() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != *..* ]]
}

on_branch() {
  git merge-base --is-ancestor "$TAG_COMMIT" "origin/$1" 2>/dev/null
}

emit() {
  echo "Detected source branch: $1 ($2)" >&2
  echo "$1"
  exit 0
}

if [[ -n "$BASE_BRANCH" ]] && ! valid_branch "$BASE_BRANCH"; then
  echo "::warning::base_branch is not a plain branch name, ignoring it and detecting the branch from git history" >&2
  BASE_BRANCH=""
fi

if ! TAG_COMMIT=$(git rev-list -n 1 "$RELEASE_VERSION" 2>/dev/null); then
  [[ -n "$BASE_BRANCH" ]] && emit "$BASE_BRANCH" "given, tag not available to check"
  echo "::error::tag $RELEASE_VERSION not found, so the source branch cannot be detected" >&2
  exit 1
fi

if [[ -n "$BASE_BRANCH" ]]; then
  if ! git rev-parse --verify -q "origin/$BASE_BRANCH" >/dev/null; then
    emit "$BASE_BRANCH" "given, branch not on remote to check"
  fi
  on_branch "$BASE_BRANCH" && emit "$BASE_BRANCH" "given"
  echo "::warning::$RELEASE_VERSION is not on $BASE_BRANCH, detecting the branch from git history instead" >&2
fi

LINE_BRANCHES=()
if [[ "$RELEASE_VERSION" =~ ^v?([0-9]+)\.([0-9]+)\. ]]; then
  LINE_BRANCHES=("release-${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}")
fi
if [[ "$RELEASE_VERSION" == *-* ]]; then
  CANDIDATES=("$DEFAULT_BRANCH" "${LINE_BRANCHES[@]}")
else
  CANDIDATES=("${LINE_BRANCHES[@]}" "$DEFAULT_BRANCH")
fi
for CANDIDATE in "${CANDIDATES[@]}"; do
  on_branch "$CANDIDATE" && emit "$CANDIDATE" "contains the tag"
done

BEST_BRANCH="$DEFAULT_BRANCH"
MAX_DISTANCE=999999
BEST_DISTANCE=$MAX_DISTANCE

if ! git rev-parse --verify "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
  echo "WARNING: default branch 'origin/$DEFAULT_BRANCH' not found on remote" >&2
fi

REMOTE_BRANCHES=$(git for-each-ref --format='%(refname:short)' \
  --contains="$TAG_COMMIT" refs/remotes/origin/ | sed 's|^origin/||' | { grep -v '^HEAD$' || true; })

if [ -z "$REMOTE_BRANCHES" ]; then
  echo "No remote branches contain this commit, falling back to '$DEFAULT_BRANCH'" >&2
else
  echo "Remote branches containing this commit: $REMOTE_BRANCHES" >&2

  for REMOTE_BRANCH in $REMOTE_BRANCHES; do
    BRANCH_BASE=$(git merge-base "origin/$DEFAULT_BRANCH" "origin/$REMOTE_BRANCH" 2>/dev/null || echo "")

    if [ -n "$BRANCH_BASE" ]; then
      if git merge-base --is-ancestor "$BRANCH_BASE" "$TAG_COMMIT" 2>/dev/null; then
        DISTANCE=$(git rev-list --count "$TAG_COMMIT..origin/$REMOTE_BRANCH")
        echo "Branch $REMOTE_BRANCH — distance from tip: $DISTANCE" >&2

        if [ "$DISTANCE" -lt "$BEST_DISTANCE" ]; then
          BEST_BRANCH=$REMOTE_BRANCH
          BEST_DISTANCE=$DISTANCE
        fi
      fi
    fi
  done

  if [ "$BEST_DISTANCE" -eq $MAX_DISTANCE ]; then
    echo "Distance algorithm found no match, falling back to first branch" >&2
    BEST_BRANCH=$(echo "$REMOTE_BRANCHES" | head -n 1)
  fi
fi

if ! valid_branch "$BEST_BRANCH"; then
  echo "::warning::the closest branch is not a plain branch name, falling back to '$DEFAULT_BRANCH'" >&2
  BEST_BRANCH="$DEFAULT_BRANCH"
fi
emit "$BEST_BRANCH" "closest tip, distance: $BEST_DISTANCE"

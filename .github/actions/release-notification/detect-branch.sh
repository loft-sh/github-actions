#!/usr/bin/env bash
# detect-branch.sh — Detect which branch a release tag was cut from.
#
# Finds all remote branches containing the tag commit, then picks the one
# whose tip is closest (fewest commits ahead).
#
# Required environment variables:
#   RELEASE_VERSION  — the release tag (e.g. v1.2.3)
#
# Optional environment variables:
#   DEFAULT_BRANCH   — fallback branch name (default: main)
#
# Output (stdout): the detected branch name

set -euo pipefail

: "${RELEASE_VERSION:?RELEASE_VERSION must be set}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

TAG_COMMIT=$(git rev-list -n 1 "$RELEASE_VERSION")

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

echo "Detected source branch: $BEST_BRANCH (distance: $BEST_DISTANCE)" >&2
echo "$BEST_BRANCH"

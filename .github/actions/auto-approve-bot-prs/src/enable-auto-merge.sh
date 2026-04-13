#!/usr/bin/env bash
# Enables GitHub's auto-merge on the PR. Never exits non-zero.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, MERGE_METHOD
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${MERGE_METHOD:?MERGE_METHOD required}"

case "$MERGE_METHOD" in
  squash|merge|rebase) ;;
  *)
    echo "::notice::Invalid merge method '$MERGE_METHOD'; skipping"
    exit 0
    ;;
esac

gh pr merge "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --auto --"$MERGE_METHOD" 2>&1 \
  || echo "::notice::gh pr merge failed; auto-merge not enabled"

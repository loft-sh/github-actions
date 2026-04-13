#!/usr/bin/env bash
# Combines two gates: merge-conflict check and approver-identity check.
# Only writes proceed=true if BOTH pass.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, PR_AUTHOR
# Writes: proceed=true|false to $GITHUB_OUTPUT (and stdout).
# Always exits 0.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${PR_AUTHOR:?PR_AUTHOR required}"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

# mergeable can be null briefly while GitHub computes metadata.
mergeable="null"
for _ in 1 2 3; do
  mergeable=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq '.mergeable // "null"' 2>/dev/null || echo "null")
  [ "$mergeable" != "null" ] && break
  sleep 3
done

if [ "$mergeable" != "true" ]; then
  echo "::notice::PR mergeability is '$mergeable', skipping"
  emit proceed false
  exit 0
fi

# GitHub forbids self-approval. Pre-empt hmarr's 422 setFailed path.
approver=$(gh api user --jq '.login' 2>/dev/null || echo "")
if [ -z "$approver" ] || [ "$approver" = "$PR_AUTHOR" ]; then
  echo "::notice::Skipping approval (approver='$approver' author='$PR_AUTHOR')"
  emit proceed false
  exit 0
fi

emit proceed true

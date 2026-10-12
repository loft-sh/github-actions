#!/usr/bin/env bash
# Bind the review to the event head that passed CI, even if a push races POST.
# API, permission and parse failures are advisory; missing required env fails.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${PR_HEAD_SHA:?PR_HEAD_SHA required}"

approval_outcome() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'approved=%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}
approval_outcome false

if [[ ! "$PR_NUMBER" =~ ^[1-9][0-9]*$ || ! "$PR_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::invalid PR number or tested head SHA; not approving"
  exit 0
fi

if ! pr_state=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" 2>/dev/null) ||
   ! current_head=$(jq -er '.head.sha | select(type == "string")' <<< "$pr_state" 2>/dev/null); then
  echo "::error::could not read the current PR head; not approving"
  exit 0
fi
if [ "$current_head" != "$PR_HEAD_SHA" ]; then
  echo "::error::PR head changed from the tested commit; not approving"
  exit 0
fi

body='Approved by the shared auto-approve workflow because this PR matched the approval criteria.

For more information, see https://github.com/loft-sh/github-actions?tab=readme-ov-file#auto-approve-bot-prs.'
if ! payload=$(jq -cn --arg sha "$PR_HEAD_SHA" --arg body "$body" \
  '{commit_id:$sha,event:"APPROVE",body:$body}' 2>/dev/null); then
  echo "::error::could not prepare approval; not approving"
  exit 0
fi
if ! review=$(printf '%s' "$payload" | gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews" \
  --method POST --input - 2>/dev/null); then
  echo "::error::could not submit approval for the tested commit"
  exit 0
fi
if ! jq -e --arg sha "$PR_HEAD_SHA" \
  'type == "object" and .commit_id == $sha and (.state | type == "string" and ascii_upcase == "APPROVED")' \
  <<< "$review" >/dev/null 2>&1; then
  echo "::error::could not verify approval for the tested commit"
  exit 0
fi
approval_outcome true
echo "::notice::PR approved at the tested commit"

#!/usr/bin/env bash
# Queue an authorized fork request on the pull request trigger.
set -euo pipefail

repo="${INPUT_REPO:?INPUT_REPO required}"
pr_number="${INPUT_PR_NUMBER:?INPUT_PR_NUMBER required}"
filter="${INPUT_REQUEST_FILTER:?INPUT_REQUEST_FILTER required}"
focus="${INPUT_REQUEST_FOCUS:-}"
target="${INPUT_REQUEST_TARGET:-}"
head_sha="${INPUT_REQUEST_HEAD_SHA:?INPUT_REQUEST_HEAD_SHA required}"
label="e2e-fork-request"
marker="<!-- e2e-fork-request -->"

payload="$(jq -cn \
  --arg filter "$filter" \
  --arg focus "$focus" \
  --arg target "$target" \
  --arg head_sha "$head_sha" \
  '{filter: $filter, focus: $focus, target: $target, "head-sha": $head_sha}')"
# shellcheck disable=SC2016 # Markdown fences are literal.
body="$(printf '%s\n\n### `/test-e2e` queued\n\n```json\n%s\n```' "$marker" "$payload")"

gh api "repos/${repo}/issues/${pr_number}/comments" -f "body=${body}" >/dev/null
gh label create "$label" --repo "$repo" \
  --description "Internal: carries an authorized E2E request to a fork pull request" \
  --color ededed 2>/dev/null || true

# Re-adding an existing label emits no event, so clear it first.
gh api --method DELETE "repos/${repo}/issues/${pr_number}/labels/${label}" >/dev/null 2>&1 || true
gh api --method POST "repos/${repo}/issues/${pr_number}/labels" -f "labels[]=${label}" >/dev/null

echo "::notice::queued ${filter} on ${repo}#${pr_number}"

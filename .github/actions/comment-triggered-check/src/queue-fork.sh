#!/usr/bin/env bash
# Queue an authorized fork request on the pull request trigger.
set -euo pipefail

repo="${INPUT_REPO:?INPUT_REPO required}"
pr_number="${INPUT_PR_NUMBER:?INPUT_PR_NUMBER required}"
filter="${INPUT_REQUEST_FILTER:?INPUT_REQUEST_FILTER required}"
focus="${INPUT_REQUEST_FOCUS:-}"
target="${INPUT_REQUEST_TARGET:-}"
head_sha="${INPUT_REQUEST_HEAD_SHA:?INPUT_REQUEST_HEAD_SHA required}"
trusted_bot="${INPUT_TRUSTED_BOT:-loft-bot}"
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

gh label create "$label" --repo "$repo" \
  --description "Internal: carries an authorized E2E request to a fork pull request" \
  --color ededed 2>/dev/null || true

# Re-adding an existing label emits no event. If it is present, removal must
# succeed; otherwise a successful POST would still not start the workflow.
labels="$(gh api "repos/${repo}/issues/${pr_number}/labels" --paginate --slurp)"
if printf '%s' "$labels" | jq -e --arg label "$label" 'any(.[][]; .name == $label)' >/dev/null; then
  gh api --method DELETE "repos/${repo}/issues/${pr_number}/labels/${label}" >/dev/null
fi

# Keep one request comment per pull request. The label event is sent only after
# the bot-authored request contains the new payload.
comments="$(gh api "repos/${repo}/issues/${pr_number}/comments" --paginate --slurp)"
comment_id="$(printf '%s' "$comments" | jq -r --arg bot "$trusted_bot" --arg marker "$marker" \
  '[.[][] | select(.user.login == $bot and (.body | contains($marker)) and (.id | type == "number"))] | last | .id // empty')"
if [[ -n "$comment_id" ]]; then
  gh api --method PATCH "repos/${repo}/issues/comments/${comment_id}" -f "body=${body}" >/dev/null
else
  gh api --method POST "repos/${repo}/issues/${pr_number}/comments" -f "body=${body}" >/dev/null
fi

gh api --method POST "repos/${repo}/issues/${pr_number}/labels" -f "labels[]=${label}" >/dev/null

echo "::notice::queued ${filter} on ${repo}#${pr_number}"

#!/usr/bin/env bash
# Resolve the fork request queued by queue-fork.sh.
set -euo pipefail

repo="${INPUT_REPO:?INPUT_REPO required}"
pr_number="${INPUT_PR_NUMBER:?INPUT_PR_NUMBER required}"
pr_head_sha="${INPUT_PR_HEAD_SHA:?INPUT_PR_HEAD_SHA required}"
label="e2e-fork-request"
marker="<!-- e2e-fork-request -->"
trusted_bot="${INPUT_TRUSTED_BOT:-loft-bot}"

emit() {
  printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
  printf '%s=%s\n' "$1" "$2"
}

if [[ "${INPUT_EVENT_NAME:-}" != "pull_request" || "${INPUT_EVENT_ACTION:-}" != "labeled" || "${INPUT_EVENT_LABEL:-}" != "$label" ]]; then
  echo "::error::this action only resolves the ${label} pull request label"
  exit 1
fi
if [[ "${INPUT_ACTOR_LOGIN:-}" != "$trusted_bot" ]]; then
  echo "::error::the fork request label was not queued by ${trusted_bot}"
  exit 1
fi

comments="$(gh api "repos/${repo}/issues/${pr_number}/comments" --paginate --slurp)"
body="$(printf '%s' "$comments" | jq -r --arg bot "$trusted_bot" --arg marker "$marker" \
  '[.[][] | select(.user.login == $bot and (.body | contains($marker)))] | last | .body // ""')"
if [[ "$body" != *"$marker"* ]]; then
  echo "::error::no queued E2E request was found; run the command again"
  exit 1
fi

# shellcheck disable=SC2016 # Markdown fences and sed addresses are literal.
payload="$(printf '%s' "$body" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d')"
if ! request_head_sha="$(printf '%s' "$payload" | jq -er '."head-sha" | select(type == "string" and length > 0)' 2>/dev/null)"; then
  echo "::error::the queued E2E request is malformed; run the command again"
  exit 1
fi
if [[ "$request_head_sha" != "$pr_head_sha" ]]; then
  echo "::error::the pull request changed after the command was requested; run the command again"
  exit 1
fi

if ! filter="$(printf '%s' "$payload" | jq -er '.filter | select(type == "string" and length > 0)' 2>/dev/null)" ||
  ! focus="$(printf '%s' "$payload" | jq -er '.focus | select(type == "string")' 2>/dev/null)" ||
  ! target="$(printf '%s' "$payload" | jq -er '.target | select(type == "string")' 2>/dev/null)"; then
  echo "::error::the queued E2E request is malformed; run the command again"
  exit 1
fi

emit "filter" "$filter"
emit "focus" "$focus"
emit "target" "$target"

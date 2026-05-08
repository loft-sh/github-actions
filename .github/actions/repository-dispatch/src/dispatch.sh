#!/usr/bin/env bash
# Send a repository_dispatch event to a target repo.
#
# Required env: GH_TOKEN, INPUT_TARGET_REPO, INPUT_EVENT_TYPE
# Optional env: INPUT_PAYLOAD (JSON object, defaults to "{}")
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required (PAT with repo scope on target)}"
: "${INPUT_TARGET_REPO:?target-repo required}"
: "${INPUT_EVENT_TYPE:?event-type required}"

PAYLOAD="${INPUT_PAYLOAD-}"
[[ -z "$PAYLOAD" ]] && PAYLOAD='{}'

# client_payload must be a JSON object per GitHub's repository_dispatch API,
# so reject arrays and scalars early — the API otherwise returns a 422 that's
# annoying to debug from caller logs.
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$PAYLOAD"; then
  echo "::error::payload must be a JSON object, got: $PAYLOAD"
  exit 1
fi

# Build the request body with jq so callers don't have to worry about quoting
# inside their event_type or payload values.
BODY=$(jq -n \
  --arg event_type "$INPUT_EVENT_TYPE" \
  --argjson client_payload "$PAYLOAD" \
  '{event_type: $event_type, client_payload: $client_payload}')

gh api -X POST "repos/${INPUT_TARGET_REPO}/dispatches" --input - <<<"$BODY"

echo "::notice::dispatched event_type=${INPUT_EVENT_TYPE} to ${INPUT_TARGET_REPO}"

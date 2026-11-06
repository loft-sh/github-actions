#!/usr/bin/env bash
# link mode: record the run a check-run was dispatched to in the command's
# reply, and redraw it. Best effort, never fails the caller.
#
# Inputs (env):
#   INPUT_CHECK_RUN_ID  check-run opened by start mode
#   INPUT_RUN_URL       URL of the run that works on that check
#   INPUT_REPO          owner/name
#   INPUT_SERVER_URL    github.server_url
#   GH_TOKEN            token with pull-requests: write
set -euo pipefail

# shellcheck source=.github/actions/comment-triggered-check/src/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=.github/actions/comment-triggered-check/src/reply.sh
source "$(dirname "${BASH_SOURCE[0]}")/reply.sh"

check_run_id="${INPUT_CHECK_RUN_ID:-}"
run_url="${INPUT_RUN_URL:-}"
repo="${INPUT_REPO:?INPUT_REPO required}"

if [[ ! "$check_run_id" =~ ^[0-9]+$ ]]; then
  echo "no check-run to link"
  exit 0
fi
if [[ ! "$run_url" =~ ^https://[^[:space:]\(\)]+$ ]]; then
  echo "::warning::run-url is not a plain https URL; not linking check-run ${check_run_id}"
  exit 0
fi

reply_id="$(reply_id_of_check "$repo" "$check_run_id")"
if [[ -z "$reply_id" ]]; then
  echo "check-run ${check_run_id} has no reply to update"
  exit 0
fi

# shellcheck disable=SC2016 # jq variables, not shell ones.
reply_refresh "$repo" "$reply_id" \
  '.runs |= map(if .id == $id then .url = $url else . end)' \
  --argjson id "$check_run_id" --arg url "$run_url"
echo "::notice::linked check-run ${check_run_id} to ${run_url}"

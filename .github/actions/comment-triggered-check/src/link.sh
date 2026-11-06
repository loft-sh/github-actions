#!/usr/bin/env bash
# link mode: store the run a check-run was dispatched to on that check, next
# to its reply id, and redraw the reply. Best effort, never fails the caller.
#
# The link lives on the check, not in the reply, so a job that overwrites the
# reply with an older view still draws this link on its read-back pass.
#
# Inputs (env):
#   INPUT_CHECK_RUN_ID  check-run opened by start mode
#   INPUT_RUN_URL       URL of the run that works on that check
#   INPUT_REPO          owner/name
#   INPUT_SERVER_URL    github.server_url
#   GH_TOKEN            token with pull-requests: write, and checks: write
#                       when it opened the check
#   INPUT_APP_TOKEN     optional GitHub App token, used when the app opened it
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

if ! GH_TOKEN="$(check_owner_token "$repo" "$check_run_id")" gh api --method PATCH \
  "repos/${repo}/check-runs/${check_run_id}" -f "external_id=${reply_id} ${run_url}" >/dev/null 2>&1; then
  echo "::warning::could not store the run link on check-run ${check_run_id}"
  exit 0
fi

reply_refresh "$repo" "$reply_id"
echo "::notice::linked check-run ${check_run_id} to ${run_url}"

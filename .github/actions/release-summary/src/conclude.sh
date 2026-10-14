#!/usr/bin/env bash
# release-summary: turn the step results into one conclusion, a warning that
# names the remedy, and a job summary line. Always exits 0: the summary is
# advisory and must never fail the release.
#
# Env: PROCEED SKIP_REASON AI_CONCLUSION RENDERED POST_OUTCOME DRY_RUN VERSION
#      PREVIOUS_TAG PR_COUNT ITEM_COUNT DROPPED_REFS PAYLOAD_FILE
set -uo pipefail

emit() { [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; return 0; }
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; return 0; }

conclusion="" reason=""
if [ "${PROCEED:-}" != "true" ]; then
  conclusion=skipped
  reason="${SKIP_REASON:-collecting changes did not finish; see the Collect merged PRs step}"
elif [ "${AI_CONCLUSION:-}" != "success" ]; then
  conclusion=failed
  reason="ai-step ended with '${AI_CONCLUSION:-no result}'; its log above has the provider error"
elif [ "${RENDERED:-}" != "true" ]; then
  conclusion=failed
  reason="the AI result rendered no items; see the Render Slack reply step"
elif [ "${DRY_RUN:-}" = "true" ]; then
  conclusion=dry-run
elif [ "${POST_OUTCOME:-}" = "success" ]; then
  conclusion=posted
else
  conclusion=failed
  reason="Slack rejected the thread reply; check the bot is in the channel and has chat:write"
fi

emit conclusion "$conclusion"
emit reason "$reason"
if [ "$conclusion" = failed ]; then
  echo "::warning::release-summary: $reason"
fi

summary "### Release summary: ${conclusion}"
summary "${VERSION:-?} compared with ${PREVIOUS_TAG:-?}: ${PR_COUNT:-0} PRs, ${ITEM_COUNT:-0} items, ${DROPPED_REFS:-0} dropped references."
[ -n "$reason" ] && summary "Reason: ${reason}"
if [ "$conclusion" = dry-run ] && [ -s "${PAYLOAD_FILE:-}" ]; then
  summary '```json'
  summary "$(cat "$PAYLOAD_FILE")"
  summary '```'
fi
exit 0

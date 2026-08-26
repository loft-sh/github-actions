#!/usr/bin/env bash
set -euo pipefail

# Required env vars: TEST_NAME, STATUS, DETAILS, PAYLOAD_FILE, RUN_URL, REPO, RUN_NUMBER
# Optional env vars: RUN_LINK_POSITION (top or bottom; defaults to top)

command -v jq >/dev/null || { echo "::error::jq is required but not found"; exit 1; }

case "$STATUS" in
  success)    EMOJI="✅"; STATUS_TEXT="Success" ;;
  failure)    EMOJI="❌"; STATUS_TEXT="Failed" ;;
  warning)    EMOJI="⚠️"; STATUS_TEXT="Warning" ;;
  cancelled)  EMOJI="⚠️"; STATUS_TEXT="Cancelled" ;;
  skipped)    EMOJI="⏭️"; STATUS_TEXT="Skipped" ;;
  *)          EMOJI="❓"; STATUS_TEXT="Unknown ($STATUS)" ;;
esac

HEADER="${EMOJI} ${TEST_NAME} ${STATUS_TEXT}"

# Slack header blocks reject >150 chars
if [[ ${#HEADER} -gt 150 ]]; then
  echo "::warning::Header exceeds 150-char Slack limit (${#HEADER} chars), truncating"
  HEADER="${HEADER:0:147}..."
fi

RUN_LINK_POSITION="${RUN_LINK_POSITION:-top}"
RUN_LINK="Workflow: <${RUN_URL}|View workflow run>"
case "$RUN_LINK_POSITION" in
  top)
    SECTION="Build URL: ${RUN_URL}"
    if [[ "$DETAILS" =~ [^[:space:]] ]]; then
      SECTION="$(printf '%s\n\n%s' "$SECTION" "$DETAILS")"
    fi
    ;;
  bottom)
    SECTION="$RUN_LINK"
    if [[ "$DETAILS" =~ [^[:space:]] ]]; then
      SECTION="$(printf '%s\n\n%s' "$DETAILS" "$SECTION")"
    fi
    ;;
  *)
    echo "::warning::invalid RUN_LINK_POSITION '$RUN_LINK_POSITION', defaulting to top"
    SECTION="Build URL: ${RUN_URL}"
    if [[ "$DETAILS" =~ [^[:space:]] ]]; then
      SECTION="$(printf '%s\n\n%s' "$SECTION" "$DETAILS")"
    fi
    ;;
esac

# Slack section blocks reject >3000 chars
if [[ ${#SECTION} -gt 3000 ]]; then
  echo "::warning::Section exceeds 3000-char Slack limit (${#SECTION} chars), truncating"
  if [[ "$RUN_LINK_POSITION" == "bottom" ]]; then
    DETAILS_LIMIT=$((3000 - ${#RUN_LINK} - 2))
    SECTION="${SECTION:0:$((DETAILS_LIMIT - 3))}..."
    SECTION="$(printf '%s\n\n%s' "$SECTION" "$RUN_LINK")"
  else
    SECTION="${SECTION:0:2997}..."
  fi
fi

jq -n \
  --arg text "$HEADER" \
  --arg section "$SECTION" \
  --arg context "<${RUN_URL}|${REPO} · Run #${RUN_NUMBER}>" \
  '{
    text: $text,
    blocks: [
      { type: "header", text: { type: "plain_text", text: $text } },
      { type: "section", text: { type: "mrkdwn", text: $section } },
      { type: "context", elements: [{ type: "mrkdwn", text: $context }] }
    ]
  }' > "$PAYLOAD_FILE"

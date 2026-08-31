#!/usr/bin/env bash
set -euo pipefail

# Required env vars: TEST_NAME, STATUS, DETAILS, PAYLOAD_FILE, RUN_URL, REPO, RUN_NUMBER
# Optional env vars: RUN_LINK_POSITION (top or bottom; defaults to top)

command -v jq >/dev/null || { echo "::error::jq is required but not found"; exit 1; }

# Slack's block limits are in characters. bash's ${#var} and ${var:0:n} follow
# the locale: characters under a UTF-8 locale, bytes under POSIX. Runners are
# not guaranteed to set one, so measuring in bash truncates roughly three times
# too early on non-ASCII text and can cut a UTF-8 sequence mid-character. jq
# always counts codepoints, so measure and cut there instead.
str_len() { printf '%s' "$1" | jq -Rs 'length'; }
clip_to() {
  printf '%s' "$2" | jq -Rrs --argjson n "$1" \
    'if length > $n then .[0:($n - 3)] + "..." else . end'
}

case "$STATUS" in
  success)    EMOJI="✅"; STATUS_TEXT="Success" ;;
  failure)    EMOJI="❌"; STATUS_TEXT="Failed" ;;
  warning)    EMOJI="⚠️"; STATUS_TEXT="" ;;
  cancelled)  EMOJI="⚠️"; STATUS_TEXT="Cancelled" ;;
  skipped)    EMOJI="⏭️"; STATUS_TEXT="Skipped" ;;
  *)          EMOJI="❓"; STATUS_TEXT="Unknown ($STATUS)" ;;
esac

HEADER="${EMOJI} ${TEST_NAME}${STATUS_TEXT:+ ${STATUS_TEXT}}"

# Slack header blocks reject >150 chars
HEADER_LEN=$(str_len "$HEADER")
if [[ $HEADER_LEN -gt 150 ]]; then
  echo "::warning::Header exceeds 150-char Slack limit (${HEADER_LEN} chars), truncating"
  HEADER=$(clip_to 150 "$HEADER")
fi

# Normalise first, so the two positions are each written once and every later
# reader (the truncation branch below included) sees a value it can trust.
RUN_LINK_POSITION="${RUN_LINK_POSITION:-top}"
if [[ "$RUN_LINK_POSITION" != "top" && "$RUN_LINK_POSITION" != "bottom" ]]; then
  echo "::warning::invalid RUN_LINK_POSITION '$RUN_LINK_POSITION', defaulting to top"
  RUN_LINK_POSITION="top"
fi

# The two positions render the link differently, not just in a different place:
# `top` keeps the bare `Build URL:` line every existing caller already gets, and
# `bottom` uses a linked label that reads better as a footer. Changing `top`
# would alter the message for ~30 call sites, so the difference is documented in
# the input rather than smoothed over here.
RUN_LINK="Workflow: <${RUN_URL}|View workflow run>"
if [[ "$RUN_LINK_POSITION" == "bottom" ]]; then
  SECTION="$RUN_LINK"
  if [[ "$DETAILS" =~ [^[:space:]] ]]; then
    SECTION="$(printf '%s\n\n%s' "$DETAILS" "$SECTION")"
  fi
else
  SECTION="Build URL: ${RUN_URL}"
  if [[ "$DETAILS" =~ [^[:space:]] ]]; then
    SECTION="$(printf '%s\n\n%s' "$SECTION" "$DETAILS")"
  fi
fi

# Slack section blocks reject >3000 chars
SECTION_LEN=$(str_len "$SECTION")
if [[ $SECTION_LEN -gt 3000 ]]; then
  echo "::warning::Section exceeds 3000-char Slack limit (${SECTION_LEN} chars), truncating"
  if [[ "$RUN_LINK_POSITION" == "bottom" ]]; then
    # Reserve the run link and the blank line above it, so truncation never
    # costs the one immutable piece of the message.
    DETAILS_LIMIT=$((3000 - $(str_len "$RUN_LINK") - 2))
    if [[ $DETAILS_LIMIT -lt 4 ]]; then
      # A run URL long enough to leave no room for details is not reachable from
      # github.server_url/run_id, but an unfloored budget here would go negative
      # and a negative slice reads as "all but the last n", overshooting 3000
      # and getting the whole message rejected. Keep the link, drop the details.
      SECTION=$(clip_to 3000 "$RUN_LINK")
    else
      SECTION="$(printf '%s\n\n%s' "$(clip_to "$DETAILS_LIMIT" "$SECTION")" "$RUN_LINK")"
    fi
  else
    SECTION=$(clip_to 3000 "$SECTION")
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

#!/usr/bin/env bash
set -euo pipefail

# Required env vars: TEST_NAME, STATUS, DETAILS, PAYLOAD_FILE, RUN_URL, REPO, RUN_NUMBER
# Optional env vars: RUN_LINK_POSITION (top, bottom or none; defaults to top),
#   FOOTER_TEXT (label for the run link in the footer; defaults to "REPO · Run #N")

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
  info)       EMOJI="📊"; STATUS_TEXT="" ;;
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

# Normalise first, so each position is written once and every later
# reader (the truncation branch below included) sees a value it can trust.
RUN_LINK_POSITION="${RUN_LINK_POSITION:-top}"
if [[ "$RUN_LINK_POSITION" != "top" && "$RUN_LINK_POSITION" != "bottom" && "$RUN_LINK_POSITION" != "none" ]]; then
  echo "::warning::invalid RUN_LINK_POSITION '$RUN_LINK_POSITION', defaulting to top"
  RUN_LINK_POSITION="top"
fi

# `none` relies on the context footer, which links the same run, so the section
# carries only the details. Slack rejects a section with empty text, so with no
# details there is nothing to drop the link in favour of: fall back to `bottom`.
if [[ "$RUN_LINK_POSITION" == "none" && ! "$DETAILS" =~ [^[:space:]] ]]; then
  echo "::warning::RUN_LINK_POSITION is none but there are no details to show, using bottom"
  RUN_LINK_POSITION="bottom"
fi

# `top` and `bottom` render the link differently, not just in a different place:
# `top` keeps the bare `Build URL:` line every existing caller already gets, and
# `bottom` uses a linked label that reads better as a footer. Changing `top`
# would alter the message for ~30 call sites, so the difference is documented in
# the input rather than smoothed over here.
RUN_LINK="Workflow: <${RUN_URL}|View workflow run>"
if [[ "$RUN_LINK_POSITION" == "none" ]]; then
  SECTION="$DETAILS"
elif [[ "$RUN_LINK_POSITION" == "bottom" ]]; then
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

# The footer is always the run link; FOOTER_TEXT only replaces its label. A
# blank value keeps the default so a caller can pass the input unconditionally.
# The label sits inside Slack's <url|label> syntax, so escape the three
# characters Slack treats as markup or a `>` would end the link early.
FOOTER_LABEL="${REPO} · Run #${RUN_NUMBER}"
if [[ "${FOOTER_TEXT:-}" =~ [^[:space:]] ]]; then
  # sed, not ${var//pat/rep}: bash 5.2's patsub_replacement expands `&` in the
  # replacement to the match, so `&lt;` would come out as `<lt;` on the runner.
  FOOTER_LABEL=$(printf '%s' "$FOOTER_TEXT" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
fi

jq -n \
  --arg text "$HEADER" \
  --arg section "$SECTION" \
  --arg context "<${RUN_URL}|${FOOTER_LABEL}>" \
  '{
    text: $text,
    blocks: [
      { type: "header", text: { type: "plain_text", text: $text } },
      { type: "section", text: { type: "mrkdwn", text: $section } },
      { type: "context", elements: [{ type: "mrkdwn", text: $context }] }
    ]
  }' > "$PAYLOAD_FILE"

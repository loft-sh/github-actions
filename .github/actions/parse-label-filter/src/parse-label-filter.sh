#!/usr/bin/env bash
# Parse the ```label-filter``` block from a PR description and decide whether a
# pull_request `edited` event should be skipped (label-filter unchanged).
#
# Inputs (env, all optional, default empty):
#   INPUT_PR_BODY             current PR body (github.event.pull_request.body)
#   INPUT_PREVIOUS_PR_BODY    PR body before an edit (github.event.changes.body.from)
#   INPUT_EVENT_NAME          github.event_name
#   INPUT_EVENT_ACTION        github.event.action
#   INPUT_LABEL_FILTER_INPUT  manual-dispatch label filter (inputs.ginkgo-label)
#
# Writes to $GITHUB_OUTPUT:
#   label-filter=<resolved>   parsed block, else dispatch input, else "pr"
#   skip-edited=true|false    true only for an edited event with unchanged filter
set -euo pipefail

pr_body="${INPUT_PR_BODY:-}"
previous_pr_body="${INPUT_PREVIOUS_PR_BODY:-}"
event_name="${INPUT_EVENT_NAME:-}"
event_action="${INPUT_EVENT_ACTION:-}"
label_filter_input="${INPUT_LABEL_FILTER_INPUT:-}"

# Extract the content of a ```label-filter``` fenced block from the given text.
# Mirrors the previous regex ('```\s*label-filter\s*\n(.*?)\n```', gms): capture
# the lines between the opening fence and the next closing fence, then collapse
# whitespace/newlines the same way the old sanitize step did.
extract_label_filter() {
  printf '%s\n' "$1" | tr -d '\r' | awk '
    /^```[[:space:]]*label-filter[[:space:]]*$/ { capture = 1; next }
    capture && /^```[[:space:]]*$/             { capture = 0; next }
    capture                                    { print }
  ' | awk '{ $1 = $1; print }' | tr -d '\n'
}

# Trim surrounding whitespace and strip line breaks, matching the old handling
# of the manual-dispatch input.
normalize() {
  printf '%s\n' "$1" | awk '{ $1 = $1; print }' | tr -d '\r\n'
}

emit() {
  printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
  printf '%s=%s\n' "$1" "$2"
}

current_filter="$(extract_label_filter "$pr_body")"
input_filter="$(normalize "$label_filter_input")"

# Precedence mirrors the previous inline job output: the PR-description block
# wins, then a manual-dispatch input, then the default "pr" suite.
if [[ -n "$current_filter" ]]; then
  label_filter="$current_filter"
elif [[ -n "$input_filter" ]]; then
  label_filter="$input_filter"
else
  label_filter="pr"
fi
emit "label-filter" "$label_filter"

# Only a pull_request `edited` event can be a no-op description edit. Anything
# else (open, reopen, synchronize, release, dispatch) always runs.
if [[ "$event_name" != "pull_request" || "$event_action" != "edited" ]]; then
  emit "skip-edited" "false"
  exit 0
fi

previous_filter="$(extract_label_filter "$previous_pr_body")"
if [[ "$current_filter" == "$previous_filter" ]]; then
  echo "::notice::Skipping e2e: PR edited but label-filter unchanged (${current_filter:-none})"
  emit "skip-edited" "true"
else
  echo "::notice::Label-filter changed from '${previous_filter:-none}' to '${current_filter:-none}', running e2e"
  emit "skip-edited" "false"
fi

#!/usr/bin/env bash
# Parse the ```label-filter``` block from a PR description and decide whether a
# pull_request `edited` event should be skipped (label-filter unchanged).
#
# Inputs (env, all optional, default empty):
#   INPUT_PR_BODY             current PR body (github.event.pull_request.body)
#   INPUT_PREVIOUS_PR_BODY    PR body before an edit (github.event.changes.body.from)
#   INPUT_EVENT_NAME          github.event_name
#   INPUT_EVENT_ACTION        github.event.action
#   INPUT_BODY_CHANGED        "true"/"false": did this edit touch the body?
#   INPUT_BASE_CHANGED        "true"/"false": did this edit retarget the base?
#   INPUT_LABEL_FILTER_INPUT  manual-dispatch label filter (inputs.ginkgo-label)
#
# Writes to $GITHUB_OUTPUT:
#   label-filter=<resolved>   parsed block, else dispatch input, else "pr"
#   skip-edited=true|false    true only for an edited event that cannot have
#                             changed what the suite would test
set -euo pipefail

pr_body="${INPUT_PR_BODY:-}"
previous_pr_body="${INPUT_PREVIOUS_PR_BODY:-}"
event_name="${INPUT_EVENT_NAME:-}"
event_action="${INPUT_EVENT_ACTION:-}"
body_changed="${INPUT_BODY_CHANGED:-}"
base_changed="${INPUT_BASE_CHANGED:-}"
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

# `edited` fires for the title, the body, the base branch, and more, and the
# payload carries a `changes` key only for what actually changed. Comparing
# bodies alone therefore cannot tell a body edit from a title edit: a non-body
# edit sends an empty previous-body, which reads as "the filter was removed".
# Callers pass what changed so the three cases can be separated. Each has a
# different answer, so a single boolean would not do:
#
#   base retargeted  -> never skip. A different base can mean a different thing
#                       under test (e.g. a caller resolving an OSS branch from
#                       base_ref), and the previous result does not carry over.
#   body untouched   -> always skip. Title, labels, assignees and milestones
#                       cannot change a filter that lives in the body.
#   body changed     -> compare the blocks, as before.
#
# Both inputs are optional: a caller that passes neither keeps the legacy
# body-comparison behaviour, so this is not a breaking change and needs no
# coordinated rollout. That legacy path still misreads a title-only edit, which
# is why passing them is documented as the correct usage.
if [[ "$base_changed" == "true" ]]; then
  echo "::notice::Not skipping e2e: the PR was retargeted to a different base branch"
  emit "skip-edited" "false"
  exit 0
fi

if [[ "$body_changed" == "false" ]]; then
  echo "::notice::Skipping e2e: PR edited but the description was not touched"
  emit "skip-edited" "true"
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

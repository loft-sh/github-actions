#!/usr/bin/env bats
# Tests for parse-label-filter.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/parse-label-filter.sh"

setup() {
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  # Start from a clean slate each test; individual tests set what they need.
  unset INPUT_PR_BODY INPUT_PREVIOUS_PR_BODY INPUT_EVENT_NAME INPUT_BODY_CHANGED INPUT_BASE_CHANGED \
    INPUT_EVENT_ACTION INPUT_LABEL_FILTER_INPUT
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

kv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1; }

# A PR body with a label-filter fenced block, indented like a real description.
body_with_filter() {
  printf '%s\n' \
    'Some description text.' \
    '' \
    '```label-filter' \
    "$1" \
    '```' \
    '' \
    'More text.'
}

@test "no label-filter block, pull_request opened -> defaults to pr, no skip" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="opened"
  export INPUT_PR_BODY="just a description, no block"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=pr" ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "label-filter block is parsed and returned" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="opened"
  export INPUT_PR_BODY="$(body_with_filter 'db-datasource && aws')"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=db-datasource && aws" ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "opening fence with a space after backticks still parses" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="synchronize"
  export INPUT_PR_BODY="$(printf '%s\n' '``` label-filter' 'istio' '```')"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=istio" ]
}

@test "dispatch input used when no block present" {
  export INPUT_EVENT_NAME="workflow_dispatch"
  export INPUT_LABEL_FILTER_INPUT="conformance"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=conformance" ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "PR block wins over dispatch input" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="opened"
  export INPUT_PR_BODY="$(body_with_filter 'from-body')"
  export INPUT_LABEL_FILTER_INPUT="from-input"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=from-body" ]
}

@test "edited with unchanged label-filter -> skip=true" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(body_with_filter 'pr')"
  export INPUT_PREVIOUS_PR_BODY="$(printf '%s\n' 'Different prose entirely.' '```label-filter' 'pr' '```')"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=true" ]
}

@test "edited with no block before or after (bot description edit) -> skip=true" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="A cursor[bot] summary was appended."
  export INPUT_PREVIOUS_PR_BODY="Original human description."

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=true" ]
}

@test "edited with changed label-filter -> skip=false" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(body_with_filter 'db-datasource')"
  export INPUT_PREVIOUS_PR_BODY="$(body_with_filter 'pr')"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "edited that adds a label-filter block where there was none -> skip=false" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(body_with_filter 'istio')"
  export INPUT_PREVIOUS_PR_BODY="No block here."

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "release event never skips" {
  export INPUT_EVENT_NAME="release"
  export INPUT_EVENT_ACTION="published"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
  [ "$(kv label-filter)" = "label-filter=pr" ]
}

@test "label filter with surrounding whitespace is trimmed" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="opened"
  export INPUT_PR_BODY="$(printf '%s\n' '```label-filter' '   istio && core   ' '```')"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=istio && core" ]
}

# A label-filter block that spans several physical lines. Each line is trimmed
# and the newlines between them are stripped (no separator inserted), so the
# block collapses into a single filter string. This mirrors the original inline
# `awk '{$1=$1; print}' | tr -d '\r\n'` sanitize step the action replaced.
@test "multi-line label-filter block is joined into a single filter" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="opened"
  export INPUT_PR_BODY="$(printf '%s\n' \
    'Intro.' \
    '' \
    '```label-filter' \
    'db-datasource && aws' \
    '|| istio' \
    '```' \
    '' \
    'Outro.')"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=db-datasource && aws|| istio" ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "edited with unchanged multi-line label-filter -> skip=true" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(printf '%s\n' \
    'A bot appended a summary.' \
    '```label-filter' \
    'db-datasource && aws' \
    '|| istio' \
    '```')"
  export INPUT_PREVIOUS_PR_BODY="$(printf '%s\n' \
    'Original human description.' \
    '```label-filter' \
    'db-datasource && aws' \
    '|| istio' \
    '```')"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=db-datasource && aws|| istio" ]
  [ "$(kv skip-edited)" = "skip-edited=true" ]
}

# ---------------------------------------------------------------------------
# Which field the edit touched (DEVOPS-1057, raised reviewing vcluster-pro#2156)
#
# `edited` fires for the title, the body, the base branch and more, and the
# payload carries a `changes` key only for what changed. Comparing bodies alone
# cannot tell a title edit from a body edit, because a non-body edit sends an
# empty previous-body that reads as "the filter was removed".

# A body shaped like vcluster-pro's PR template, whose label-filter block is
# pre-filled with `none` — the default shape for a template-following PR, and
# what makes the legacy misread bite rather than being harmless.
template_body() {
  printf '%s\n' '## What' 'stuff' '' '```label-filter' 'none' '```'
}

@test "title-only edit -> skip=true (body untouched cannot change the filter)" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(template_body)"
  # No changes.body key in the payload, so the caller passes body-changed=false
  # and previous-pr-body arrives empty.
  export INPUT_PREVIOUS_PR_BODY=""
  export INPUT_BODY_CHANGED="false"
  export INPUT_BASE_CHANGED="false"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=true" ]
  [[ "$output" == *"description was not touched"* ]]
}

@test "regression: legacy caller misreads a title-only edit as a filter change" {
  # Pins the behaviour the new inputs exist to fix, and the reason omitting them
  # is not merely a style choice. Same event as above from a caller that passes
  # neither input: "none" is compared against "", so the suite re-runs.
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(template_body)"
  export INPUT_PREVIOUS_PR_BODY=""

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "base retarget -> skip=false even though the body did not change" {
  # A retarget carries changes.base and no changes.body, so body-changed=false.
  # It must still run: a caller that resolves anything from base_ref (an OSS
  # branch, a chart line) is now testing a different pairing, and the previous
  # result does not carry over. This is why one body-changed boolean is not
  # enough — it would report this as skippable.
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(template_body)"
  export INPUT_PREVIOUS_PR_BODY=""
  export INPUT_BODY_CHANGED="false"
  export INPUT_BASE_CHANGED="true"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
  [[ "$output" == *"retargeted"* ]]
}

@test "base retarget wins over an unchanged label-filter" {
  # Ordering check: base is tested before the block comparison, so a simultaneous
  # base+body edit that leaves the filter identical still runs.
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(template_body)"
  export INPUT_PREVIOUS_PR_BODY="$(template_body)"
  export INPUT_BODY_CHANGED="true"
  export INPUT_BASE_CHANGED="true"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "body edit with body-changed=true still compares the blocks" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(printf '%s\n' 'bot summary appended' '```label-filter' 'none' '```')"
  export INPUT_PREVIOUS_PR_BODY="$(template_body)"
  export INPUT_BODY_CHANGED="true"
  export INPUT_BASE_CHANGED="false"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=true" ]
}

@test "body that gained a label-filter block still runs" {
  # The case that rules out `changes.body.from || pull_request.body` as a caller
  # workaround: the body genuinely changed FROM empty, so there is a new filter
  # to honour and skipping would drop the suite the author just requested.
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(printf '%s\n' '```label-filter' 'istio' '```')"
  export INPUT_PREVIOUS_PR_BODY=""
  export INPUT_BODY_CHANGED="true"
  export INPUT_BASE_CHANGED="false"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv label-filter)" = "label-filter=istio" ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "the new inputs never make a non-edited event skippable" {
  # body-changed=false is about an edit, not a licence to skip. A synchronize
  # carries no changes at all, and a caller wiring these from the payload would
  # pass false for it.
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="synchronize"
  export INPUT_PR_BODY="$(template_body)"
  export INPUT_BODY_CHANGED="false"
  export INPUT_BASE_CHANGED="false"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

@test "unexpected input values fall back to comparing, never to skipping" {
  # Default-deny on garbage: only the exact string "false" means "body untouched"
  # and only "true" means "retargeted", so a caller passing an expression that
  # rendered oddly gets the conservative path rather than a silent skip.
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="edited"
  export INPUT_PR_BODY="$(template_body)"
  export INPUT_PREVIOUS_PR_BODY=""
  export INPUT_BODY_CHANGED="False"
  export INPUT_BASE_CHANGED="yes"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv skip-edited)" = "skip-edited=false" ]
}

#!/usr/bin/env bats
# Tests for parse-label-filter.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/parse-label-filter.sh"

setup() {
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  # Start from a clean slate each test; individual tests set what they need.
  unset INPUT_PR_BODY INPUT_PREVIOUS_PR_BODY INPUT_EVENT_NAME \
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

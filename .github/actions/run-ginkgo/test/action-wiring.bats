#!/usr/bin/env bats
# Contract tests for the composite-action seam that shell unit tests cannot run.

ACTION="$BATS_TEST_DIRNAME/../action.yml"

@test "declares an optional ginkgo-focus input" {
  run grep -A4 '^  ginkgo-focus:' "$ACTION"
  [ "$status" -eq 0 ]
  [[ "$output" == *'required: false'* ]]
  [[ "$output" == *'default: ""'* ]]
}

@test "failed-only rerun focus takes precedence over requested focus" {
  run grep -F 'GINKGO_FOCUS: ${{ steps.rerun-focus.outputs.focus || inputs.ginkgo-focus }}' "$ACTION"
  [ "$status" -eq 0 ]
}

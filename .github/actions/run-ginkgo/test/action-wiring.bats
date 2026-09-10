#!/usr/bin/env bats
# Contract tests for the composite-action seam that shell unit tests cannot run.

ACTION="$BATS_TEST_DIRNAME/../action.yml"
CONCLUSION_SCRIPT="$BATS_TEST_DIRNAME/../src/derive-conclusion.sh"

@test "conclusion script is executable" {
  [ -x "$CONCLUSION_SCRIPT" ]
}

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

@test "summary and upload treat either focus source as a partial run" {
  local expected="FOCUS_ACTIVE: \${{ steps.rerun-focus.outputs.focus != '' || inputs.ginkgo-focus != '' }}"
  run grep -F "$expected" "$ACTION"
  [ "$status" -eq 0 ]
  [ "$(grep -Fc "$expected" "$ACTION")" -eq 2 ]
}

@test "declares the empty-selection policy and conclusion outputs" {
  run grep -A4 '^  empty-selection-conclusion:' "$ACTION"
  [ "$status" -eq 0 ]
  [[ "$output" == *'required: false'* ]]
  [[ "$output" == *'default: ""'* ]]

  grep -Fq 'value: ${{ steps.derive-conclusion.outputs.check-conclusion }}' "$ACTION"
  grep -Fq 'value: ${{ steps.derive-conclusion.outputs.check-summary }}' "$ACTION"
}

@test "derives a conclusion after the test command regardless of its result" {
  run grep -A8 '^    - name: Derive check conclusion' "$ACTION"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id: derive-conclusion'* ]]
  [[ "$output" == *"if: always() && inputs.empty-selection-conclusion != ''"* ]]
  [[ "$output" == *'INPUT_EMPTY_SELECTION_CONCLUSION: ${{ inputs.empty-selection-conclusion }}'* ]]
  [[ "$output" == *'INPUT_FOCUS: ${{ steps.rerun-focus.outputs.focus || inputs.ginkgo-focus }}'* ]]
}

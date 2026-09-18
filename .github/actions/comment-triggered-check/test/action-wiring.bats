#!/usr/bin/env bats
# shellcheck disable=SC2016 # GitHub expressions are literal test fixtures.

ACTION="${ACTION:-$BATS_TEST_DIRNAME/../action.yml}"
START="$BATS_TEST_DIRNAME/../src/start.sh"

@test "action metadata exposes one target-selection input and defaults its options" {
  run grep -A3 '^  allowed-targets:' "$ACTION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default: 'pro oss'"* ]]
  [ "$(grep -Fc '  target-name:' "$ACTION")" -eq 1 ]

  run grep -Fq 'parse-target:' "$ACTION"
  [ "$status" -ne 0 ]
  run grep -Fq 'current-target:' "$ACTION"
  [ "$status" -ne 0 ]

  grep -Fq 'target:' "$ACTION"
  grep -Fq 'value: ${{ steps.start.outputs.target || steps.resolve-fork.outputs.target }}' "$ACTION"
  grep -Fq 'reason-title:' "$ACTION"
  grep -Fq 'value: ${{ steps.start.outputs.reason-title }}' "$ACTION"
  grep -Fq 'reason-guidance:' "$ACTION"
  grep -Fq 'value: ${{ steps.start.outputs.reason-guidance }}' "$ACTION"
}

@test "start step passes target configuration without a separate parse toggle" {
  grep -Fq 'INPUT_ALLOWED_TARGETS: ${{ inputs.allowed-targets }}' "$ACTION"
  grep -Fq 'INPUT_TARGET_NAME: ${{ inputs.target-name }}' "$ACTION"
  run grep -Fq 'INPUT_PARSE_TARGET:' "$ACTION"
  [ "$status" -ne 0 ]
}

@test "action metadata owns the allowed-target default" {
  run grep -Fq 'INPUT_ALLOWED_TARGETS-pro oss' "$START"
  [ "$status" -ne 0 ]
}

@test "fork support is opt-in and exposes the resolved repository relationship" {
  run grep -A3 '^  allow-forks:' "$ACTION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default: 'false'"* ]]
  grep -Fq 'INPUT_ALLOW_FORKS: ${{ inputs.allow-forks }}' "$ACTION"
  grep -Fq 'is-fork:' "$ACTION"
  grep -Fq 'value: ${{ steps.start.outputs.is-fork }}' "$ACTION"
  grep -Fq 'dispatch-ref:' "$ACTION"
  grep -Fq 'value: ${{ steps.start.outputs.dispatch-ref }}' "$ACTION"
}

@test "fork handoff modes queue and resolve the authorized request" {
  grep -Fq "inputs.mode != 'queue-fork'" "$ACTION"
  grep -Fq "inputs.mode != 'resolve-fork'" "$ACTION"
  grep -Fq "if: inputs.mode == 'queue-fork'" "$ACTION"
  grep -Fq 'run: ${{ github.action_path }}/src/queue-fork.sh' "$ACTION"
  grep -Fq "if: inputs.mode == 'resolve-fork'" "$ACTION"
  grep -Fq 'run: ${{ github.action_path }}/src/resolve-fork.sh' "$ACTION"
  grep -Fq 'INPUT_REQUEST_HEAD_SHA: ${{ inputs.request-head-sha }}' "$ACTION"
  grep -Fq 'INPUT_PR_HEAD_SHA: ${{ inputs.pr-head-sha }}' "$ACTION"
  grep -Fq 'INPUT_ACTOR_LOGIN: ${{ github.actor }}' "$ACTION"
  grep -Fq 'INPUT_TRUSTED_BOT: ${{ inputs.trusted-bot }}' "$ACTION"
  grep -Fq 'value: ${{ steps.start.outputs.filter || steps.resolve-fork.outputs.filter }}' "$ACTION"
  grep -Fq 'value: ${{ steps.start.outputs.focus || steps.resolve-fork.outputs.focus }}' "$ACTION"
  grep -Fq 'value: ${{ steps.start.outputs.target || steps.resolve-fork.outputs.target }}' "$ACTION"
}

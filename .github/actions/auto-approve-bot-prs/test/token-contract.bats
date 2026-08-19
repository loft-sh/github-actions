#!/usr/bin/env bats

ACTION="$BATS_TEST_DIRNAME/../action.yml"
WORKFLOW="$BATS_TEST_DIRNAME/../../../workflows/auto-approve-bot-prs.yaml"

@test "composite accepts an optional merge token" {
  run grep -F "  merge-token:" "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F 'GH_TOKEN: ${{ inputs.merge-token || inputs.github-token }}' "$ACTION"
  [ "$status" -eq 0 ]
}

@test "reusable workflow threads the optional merge token to the composite" {
  run grep -F "      merge-token:" "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F 'merge-token: ${{ secrets.merge-token }}' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "approval still uses only the approval token" {
  run grep -F 'github-token: ${{ inputs.github-token }}' "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F 'github-token: ${{ secrets.gh-access-token }}' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "the tested head is rechecked after CI and passed to every merge request" {
  [ "$(grep -Fc 'EXPECTED_HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$ACTION")" -eq 2 ]
  run grep -F "id: recheck" "$ACTION"
  [ "$status" -eq 0 ]
  [ "$(grep -Fc "steps.recheck.outputs.proceed == 'true'" "$ACTION")" -eq 2 ]
  run grep -F 'PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$ACTION"
  [ "$status" -eq 0 ]
}

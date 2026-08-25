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

@test "a failed approval blocks only the opt-in bypass merge" {
  # The bypass path must not merge a PR carrying no approval at all. Existing
  # callers leave merge-when-blocked off and retain their best-effort approval
  # behavior, including release orchestration that already depends on it.
  run grep -F "      id: approve" "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F 'APPROVAL_OUTCOME: ${{ steps.approve.outcome }}' "$ACTION"
  [ "$status" -eq 0 ]
  # outcome, not conclusion — continue-on-error rewrites conclusion to success.
  run grep -F "steps.approve.conclusion" "$ACTION"
  [ "$status" -ne 0 ]
}

@test "merge-when-blocked reaches the merge script and the composite" {
  # The feature's only activation conduit: a typo here leaves it inert with the
  # whole suite green, since every script test sets the env var directly.
  run grep -F 'MERGE_WHEN_BLOCKED: ${{ inputs.merge-when-blocked }}' "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F "  merge-when-blocked:" "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F 'merge-when-blocked: ${{ inputs.merge-when-blocked }}' "$WORKFLOW"
  [ "$status" -eq 0 ]
  run grep -F "      merge-when-blocked:" "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "the reusable job fails only when a requested merge cannot be performed" {
  # Approval-only callers keep the historical best-effort job. Callers asking
  # for a merge must see a red check when every merge path is refused.
  run grep -F 'continue-on-error: ${{ !inputs.auto-merge }}' "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "the tested head is rechecked after CI and passed to every merge request" {
  [ "$(grep -Fc 'EXPECTED_HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$ACTION")" -eq 2 ]
  run grep -F "id: recheck" "$ACTION"
  [ "$status" -eq 0 ]
  run grep -F 'run: ${{ github.action_path }}/src/check-pr-after-ci.sh' "$ACTION"
  [ "$status" -eq 0 ]
  [ "$(grep -Fc "steps.recheck.outputs.proceed == 'true'" "$ACTION")" -eq 2 ]
  run grep -F 'PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}' "$ACTION"
  [ "$status" -eq 0 ]
}

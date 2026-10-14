#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/conclude.sh"

setup() {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  export PAYLOAD_FILE="$BATS_TEST_TMPDIR/payload.json"
  export PROCEED=true SKIP_REASON="" AI_CONCLUSION=success RENDERED=true
  export POST_RESULT=posted POST_REASON="" DRY_RUN=false VERSION=v1.1.0 PREVIOUS_TAG=v1.0.0
  export PR_COUNT=3 ITEM_COUNT=2 DROPPED_REFS=0
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
}

out() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT"; }

@test "posted when every step succeeded" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = posted ]
  [ "$(out reason)" = "" ]
  grep -q 'v1.1.0 compared with v1.0.0: 3 PRs, 2 items' "$GITHUB_STEP_SUMMARY"
}

@test "skipped carries the collector's reason" {
  PROCEED=false SKIP_REASON="no Slack bot token" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = skipped ]
  [ "$(out reason)" = "no Slack bot token" ]
}

@test "skipped when the collector produced nothing at all" {
  PROCEED="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = skipped ]
  [[ "$(out reason)" == *"Collect merged PRs"* ]]
}

@test "failed AI step warns and exits 0" {
  AI_CONCLUSION=failed run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = failed ]
  [[ "$output" == *"::warning::release-summary: ai-step ended with 'failed'"* ]]
}

@test "failed AI step carries ai-step's reason" {
  AI_CONCLUSION=failed AI_REASON="response truncated at max-tokens 16000; raise max-tokens" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = failed ]
  [[ "$(out reason)" == *"truncated at max-tokens 16000"* ]]
}

@test "skipped AI step is a skip with ai-step's reason, not a failure" {
  AI_CONCLUSION=skipped AI_REASON="unknown effort 'max'" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = skipped ]
  [ "$(out reason)" = "ai-step skipped: unknown effort 'max'" ]
  [[ "$output" != *"::warning::"* ]]
}

@test "missing render warns and exits 0" {
  RENDERED=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = failed ]
}

@test "dry run writes the payload to the job summary" {
  echo '{"text":"hello"}' > "$PAYLOAD_FILE"
  DRY_RUN=true POST_RESULT="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = dry-run ]
  grep -q '"text":"hello"' "$GITHUB_STEP_SUMMARY"
}

@test "rejected Slack post carries the poster's remedy and exits 0" {
  POST_RESULT=failed POST_REASON="Slack rejected the reply (not_in_channel); invite the bot" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = failed ]
  [[ "$output" == *"invite the bot"* ]]
}

@test "a summary replaced in place is updated, not a failure" {
  POST_RESULT=updated run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = updated ]
  [ "$(out reason)" = "" ]
  [[ "$output" != *"::warning::"* ]]
}

@test "an unreadable thread is a skip" {
  POST_RESULT=skipped POST_REASON="could not read the banner thread (missing_scope)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = skipped ]
}

@test "a post step that never reported is a failure, still exit 0" {
  POST_RESULT="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = failed ]
  [[ "$(out reason)" == *"Post thread reply"* ]]
}

@test "exits 0 with no environment at all" {
  run env -i bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

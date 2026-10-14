#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/conclude.sh"

setup() {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  export PAYLOAD_FILE="$BATS_TEST_TMPDIR/payload.json"
  export PROCEED=true SKIP_REASON="" AI_CONCLUSION=success RENDERED=true
  export POST_OUTCOME=success DRY_RUN=false VERSION=v1.1.0 PREVIOUS_TAG=v1.0.0
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

@test "missing render warns and exits 0" {
  RENDERED=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = failed ]
}

@test "dry run writes the payload to the job summary" {
  echo '{"text":"hello"}' > "$PAYLOAD_FILE"
  DRY_RUN=true POST_OUTCOME="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = dry-run ]
  grep -q '"text":"hello"' "$GITHUB_STEP_SUMMARY"
}

@test "rejected Slack post names the bot remedy and exits 0" {
  POST_OUTCOME=failure run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out conclusion)" = failed ]
  [[ "$output" == *"chat:write"* ]]
}

@test "exits 0 with no environment at all" {
  run env -i bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

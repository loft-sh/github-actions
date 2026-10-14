#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../validate-transport.sh"

setup() {
  export STATUS=success DRY_RUN=false HAS_WEBHOOK=false HAS_BOT_TOKEN=false HAS_CHANNEL=false
}

@test "webhook alone is enough for a success banner" {
  HAS_WEBHOOK=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "bot token with channel is enough for a success banner" {
  HAS_BOT_TOKEN=true HAS_CHANNEL=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "no transport fails a success banner" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No Slack transport"* ]]
}

@test "bot token without channel warns and needs the webhook" {
  HAS_BOT_TOKEN=true run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"without slack_channel_id"* ]]
  HAS_BOT_TOKEN=true HAS_WEBHOOK=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"without slack_channel_id"* ]]
}

@test "failure notifications need the webhook" {
  STATUS=failure HAS_BOT_TOKEN=true HAS_CHANNEL=true run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"webhook_url"* ]]
  STATUS=failure HAS_WEBHOOK=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a dry run of a success banner checks the failure path too" {
  DRY_RUN=true HAS_BOT_TOKEN=true HAS_CHANNEL=true run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failure notifications post through webhook_url"* ]]
  DRY_RUN=true HAS_WEBHOOK=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

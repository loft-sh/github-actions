#!/usr/bin/env bats
# Tests for should-notify.sh — the gate that decides whether a Slack
# notification is sent. Cancelled and skipped runs must stay silent.

SCRIPT="$BATS_TEST_DIRNAME/../should-notify.sh"

setup() {
  MOCK_DIR=$(mktemp -d)
  export GITHUB_OUTPUT="$MOCK_DIR/output"
  : > "$GITHUB_OUTPUT"

  # Sensible defaults; individual tests override STATUS / WEBHOOK_URL.
  export STATUS="success"
  export WEBHOOK_URL="https://hooks.slack.com/services/T000/B000/xxx"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# Helper: read the notify value written to GITHUB_OUTPUT
notify_value() {
  sed -n 's/^notify=//p' "$GITHUB_OUTPUT"
}

# --- Statuses that should notify ---

@test "success notifies" {
  STATUS="success" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(notify_value)" = "true" ]
}

@test "failure notifies" {
  STATUS="failure" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(notify_value)" = "true" ]
}

@test "info notifies" {
  STATUS="info" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(notify_value)" = "true" ]
}

# --- Statuses that must stay silent (the bug this fixes) ---

@test "cancelled does not notify" {
  STATUS="cancelled" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(notify_value)" = "false" ]
}

@test "skipped does not notify" {
  STATUS="skipped" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(notify_value)" = "false" ]
}

@test "cancelled emits an explanatory notice" {
  STATUS="cancelled" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" == *"cancelled"* ]]
}

# --- Empty webhook (fork PRs) wins over an otherwise-notifying status ---

@test "empty webhook does not notify even on failure" {
  STATUS="failure" WEBHOOK_URL="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(notify_value)" = "false" ]
  [[ "$output" == *"webhook-url is empty"* ]]
}

@test "empty webhook does not notify on success" {
  STATUS="success" WEBHOOK_URL="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(notify_value)" = "false" ]
}

# --- Error handling ---

@test "fails when STATUS is unset" {
  unset STATUS
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when GITHUB_OUTPUT is unset" {
  unset GITHUB_OUTPUT
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "exactly one notify line is written" {
  STATUS="success" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^notify=' "$GITHUB_OUTPUT")" -eq 1 ]
}

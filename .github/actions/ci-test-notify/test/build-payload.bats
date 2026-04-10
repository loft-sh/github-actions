#!/usr/bin/env bats
# Tests for build-payload.sh

SCRIPT="$BATS_TEST_DIRNAME/../build-payload.sh"

setup() {
  MOCK_DIR=$(mktemp -d)
  export PAYLOAD_FILE="$MOCK_DIR/payload.json"

  # Set required env vars with defaults
  export TEST_NAME="My Test Suite"
  export STATUS="success"
  export DETAILS=""
  export RUN_URL="https://github.com/org/repo/actions/runs/12345"
  export REPO="org/repo"
  export RUN_NUMBER="42"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# Helper: extract a field from the payload JSON
payload_field() {
  jq -r "$1" "$PAYLOAD_FILE"
}

# --- Status mapping tests ---

@test "success status produces correct emoji and text" {
  STATUS="success" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(payload_field '.text')" == *"✅"* ]]
  [[ "$(payload_field '.text')" == *"Success"* ]]
}

@test "failure status produces correct emoji and text" {
  STATUS="failure" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(payload_field '.text')" == *"❌"* ]]
  [[ "$(payload_field '.text')" == *"Failed"* ]]
}

@test "cancelled status produces correct emoji and text" {
  STATUS="cancelled" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(payload_field '.text')" == *"⚠️"* ]]
  [[ "$(payload_field '.text')" == *"Cancelled"* ]]
}

@test "skipped status produces correct emoji and text" {
  STATUS="skipped" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(payload_field '.text')" == *"⏭️"* ]]
  [[ "$(payload_field '.text')" == *"Skipped"* ]]
}

@test "unknown status produces fallback emoji and includes raw value" {
  STATUS="weird" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(payload_field '.text')" == *"❓"* ]]
  [[ "$(payload_field '.text')" == *"Unknown (weird)"* ]]
}

# --- Header and test name ---

@test "header includes the test name" {
  TEST_NAME="E2E Ginkgo Nightly Tests" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(payload_field '.text')" == *"E2E Ginkgo Nightly Tests"* ]]
}

# --- Details handling ---

@test "section contains build URL without details" {
  DETAILS="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local section
  section=$(payload_field '.blocks[1].text.text')
  [[ "$section" == "Build URL: https://github.com/org/repo/actions/runs/12345" ]]
}

@test "section contains build URL and details when provided" {
  DETAILS="E2E Tests: failure" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local section
  section=$(payload_field '.blocks[1].text.text')
  [[ "$section" == *"Build URL:"* ]]
  [[ "$section" == *"E2E Tests: failure"* ]]
}

@test "whitespace-only details are ignored" {
  DETAILS="   " run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local section
  section=$(payload_field '.blocks[1].text.text')
  [[ "$section" == "Build URL: https://github.com/org/repo/actions/runs/12345" ]]
}

@test "multiline details are preserved" {
  DETAILS=$'Line one\nLine two\nLine three' run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local section
  section=$(payload_field '.blocks[1].text.text')
  [[ "$section" == *"Line one"* ]]
  [[ "$section" == *"Line three"* ]]
}

# --- Block Kit structure ---

@test "payload has correct block structure" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(payload_field '.blocks | length')" -eq 3 ]
  [ "$(payload_field '.blocks[0].type')" = "header" ]
  [ "$(payload_field '.blocks[1].type')" = "section" ]
  [ "$(payload_field '.blocks[2].type')" = "context" ]
}

@test "context block contains repo and run number" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local context
  context=$(payload_field '.blocks[2].elements[0].text')
  [[ "$context" == *"org/repo"* ]]
  [[ "$context" == *"Run #42"* ]]
}

# --- Error handling ---

@test "fails when jq is not available" {
  # Build a minimal PATH that has bash but not jq
  local fake_bin
  fake_bin=$(mktemp -d)
  ln -s "$(command -v bash)" "$fake_bin/bash"
  PATH="$fake_bin" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq is required"* ]]
  rm -rf "$fake_bin"
}

# --- Header truncation ---

@test "header is truncated when exceeding 150 chars" {
  TEST_NAME="$(printf 'A%.0s' {1..145})" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local header
  header=$(payload_field '.blocks[0].text.text')
  [ "${#header}" -le 150 ]
  [[ "$header" == *"..."* ]]
}

@test "header is not truncated when under 150 chars" {
  TEST_NAME="Short Name" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local header
  header=$(payload_field '.blocks[0].text.text')
  [[ "$header" != *"..."* ]]
}

# --- Section truncation ---

@test "section is truncated when exceeding 3000 chars" {
  DETAILS="$(printf 'X%.0s' {1..3000})" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local section
  section=$(payload_field '.blocks[1].text.text')
  [ "${#section}" -le 3000 ]
  [[ "$section" == *"..."* ]]
}

@test "section is not truncated when under 3000 chars" {
  DETAILS="Short details" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local section
  section=$(payload_field '.blocks[1].text.text')
  [[ "$section" != *"..."* ]]
}

# --- Missing env vars ---

@test "fails when STATUS is unset" {
  unset STATUS
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when PAYLOAD_FILE is unset" {
  unset PAYLOAD_FILE
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when TEST_NAME is unset" {
  unset TEST_NAME
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "output is valid JSON" {
  DETAILS="*Bold* and \`code\` with <special> & chars" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  jq empty "$PAYLOAD_FILE"
}

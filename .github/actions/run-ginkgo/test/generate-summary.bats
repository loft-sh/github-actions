#!/usr/bin/env bats
# Tests for generate-summary.sh

SCRIPT="$BATS_TEST_DIRNAME/../src/generate-summary.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

setup() {
  MOCK_DIR=$(mktemp -d)
  export GITHUB_OUTPUT="$MOCK_DIR/output"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# Helper: extract the failure-summary multiline value from GITHUB_OUTPUT
get_summary() {
  # Parse heredoc-style output: failure-summary<<EOF ... EOF
  sed -n '/^failure-summary<<EOF$/,/^EOF$/{ /^failure-summary<<EOF$/d; /^EOF$/d; p; }' "$GITHUB_OUTPUT"
}

# Helper: get single-line failure-summary value
get_summary_line() {
  grep '^failure-summary=' "$GITHUB_OUTPUT" | cut -d= -f2-
}

# --- All tests passed ---

@test "all-passed report shows success message" {
  REPORT_FILE="$FIXTURES/all-passed.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"All tests passed!"* ]]
  [[ "$summary" == *"5/5"* ]]
}

@test "all-passed report does not show Failed Tests section" {
  REPORT_FILE="$FIXTURES/all-passed.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" != *"Failed Tests"* ]]
}

@test "all-passed report shows correct duration" {
  REPORT_FILE="$FIXTURES/all-passed.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"Duration: 120s"* ]]
}

@test "all-passed report does not show skipped or pending lines" {
  REPORT_FILE="$FIXTURES/all-passed.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" != *"Skipped:"* ]]
  [[ "$summary" != *"Pending:"* ]]
}

# --- With failures ---

@test "failure report shows failed count" {
  REPORT_FILE="$FIXTURES/with-failures.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"Failed: 2"* ]]
  [[ "$summary" == *"Passed: 2"* ]]
}

@test "failure report lists failed tests with details" {
  REPORT_FILE="$FIXTURES/with-failures.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"[FAILED]"* ]]
  [[ "$summary" == *"syncs pods"* ]]
  [[ "$summary" == *"sync_test.go:20"* ]]
}

@test "panicked tests are counted as failures" {
  REPORT_FILE="$FIXTURES/with-failures.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"[PANICKED]"* ]]
  [[ "$summary" == *"handles network policies"* ]]
  [[ "$summary" == *"network_test.go:50"* ]]
}

@test "failure report shows skipped count" {
  REPORT_FILE="$FIXTURES/with-failures.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"Skipped: 1"* ]]
}

@test "failure report shows correct duration" {
  REPORT_FILE="$FIXTURES/with-failures.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"Duration: 180s"* ]]
}

@test "failure report shows Failed Tests section" {
  REPORT_FILE="$FIXTURES/with-failures.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"*Failed Tests:*"* ]]
}

# --- With pending ---

@test "pending report shows pending count" {
  REPORT_FILE="$FIXTURES/with-pending.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"Pending: 1"* ]]
}

@test "pending report shows skipped count" {
  REPORT_FILE="$FIXTURES/with-pending.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"Skipped: 1"* ]]
}

@test "pending report shows all passed when no failures" {
  REPORT_FILE="$FIXTURES/with-pending.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"All tests passed!"* ]]
}

# --- Missing report file ---

@test "missing report file produces fallback message" {
  REPORT_FILE="$MOCK_DIR/nonexistent.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local line
  line="$(get_summary_line)"
  [[ "$line" == "No detailed failure summary available" ]]
}

@test "missing report file emits warning" {
  REPORT_FILE="$MOCK_DIR/nonexistent.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"JSON report not found"* ]]
}

# --- Error handling ---

@test "fails when jq is not available" {
  local fake_bin
  fake_bin=$(mktemp -d)
  ln -s "$(command -v bash)" "$fake_bin/bash"
  ln -s "$(command -v ls)" "$fake_bin/ls"
  ln -s "$(command -v cat)" "$fake_bin/cat"
  ln -s "$(command -v echo)" "$fake_bin/echo"
  ln -s "$(command -v grep)" "$fake_bin/grep"
  ln -s "$(command -v sed)" "$fake_bin/sed"
  ln -s "$(command -v dirname)" "$fake_bin/dirname"
  ln -s "$(command -v test)" "$fake_bin/test"
  ln -s "$(command -v [)" "$fake_bin/["
  REPORT_FILE="$FIXTURES/all-passed.json" PATH="$fake_bin" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq is required"* ]]
  rm -rf "$fake_bin"
}

# --- Container hierarchy ---

@test "failure output includes container hierarchy" {
  REPORT_FILE="$FIXTURES/with-failures.json" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local summary
  summary="$(get_summary)"
  [[ "$summary" == *"VCluster Sync"* ]]
  [[ "$summary" == *"VCluster Networking"* ]]
}

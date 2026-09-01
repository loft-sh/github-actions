#!/usr/bin/env bats
# Tests for execute-tests.sh argument construction.
# Mocks `ginkgo` to capture the arguments it would receive.

load helpers

SCRIPT="$BATS_TEST_DIRNAME/../src/execute-tests.sh"

setup() {
  MOCK_DIR=$(mktemp -d)
  setup_ginkgo_mock
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# --- Label-based tests ---

@test "label-based: passes --label-filter as-is" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="my-suite"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "--label-filter=my-suite"
}

@test "label-based: passes label with || pr when caller includes it" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="my-suite || pr"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "--label-filter=my-suite || pr"
}

@test "label-based: adds -r for recursive search" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="my-suite"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "-r"
}

@test "label-based: trims whitespace from label" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="  my-suite  "
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "--label-filter=my-suite"
}

# --- Directory-based tests ---

@test "directory-based: does not add --label-filter or -r when ginkgo-label is empty" {
  cd "$WORK_DIR"
  export GINKGO_LABEL=""
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q "\-\-label-filter" "$MOCK_ARGS_FILE"
  ! grep -q "^-r$" "$MOCK_ARGS_FILE"
}

@test "directory-based: uses test-dir directly" {
  cd "$WORK_DIR"
  export TEST_DIR="e2e-next/suites/basic"
  export GINKGO_LABEL=""
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "."
}

# --- Common flags ---

@test "passes --timeout from env" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  export TIMEOUT="120m"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "--timeout=120m"
}

@test "passes --procs from env" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  export PROCS="4"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "--procs=4"
}

@test "always includes --github-output" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "--github-output"
}

@test "always includes --json-report" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "\-\-json-report=" "$MOCK_ARGS_FILE"
}

# --- Additional flags ---

@test "additional-ginkgo-flags are appended" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  export ADDITIONAL_GINKGO_FLAGS="-v --skip-package=linters"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "-v"
  has_arg "--skip-package=linters"
}

@test "additional-args are passed after --" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  export ADDITIONAL_ARGS="--vcluster-image=ghcr.io/loft-sh/vcluster:test --teardown=false"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx -- '--' "$MOCK_ARGS_FILE"
  has_arg "--vcluster-image=ghcr.io/loft-sh/vcluster:test"
  has_arg "--teardown=false"
}

@test "no -- separator when additional-args is empty" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  export ADDITIONAL_ARGS=""
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qx -- '--' "$MOCK_ARGS_FILE"
}

# --- Report directory ---

@test "creates test-reports directory" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$WORK_DIR/test-reports" ]
}

@test "json-report uses absolute path" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "\-\-json-report=$WORK_DIR/test-reports/report.json" "$MOCK_ARGS_FILE"
}

# --- Focused rerun ---

@test "passes GINKGO_FOCUS through as a single --focus argument" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  export GINKGO_FOCUS='^Suite Alpha syncs pods \(a\)$|^Suite Beta(?: |$)'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg '--focus=^Suite Alpha syncs pods \(a\)$|^Suite Beta(?: |$)'
}

@test "no --focus argument when GINKGO_FOCUS is unset" {
  cd "$WORK_DIR"
  export GINKGO_LABEL="suite"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q -- '--focus=' "$MOCK_ARGS_FILE"
}

# --- flake-attempts ---

@test "flake-attempts: 2 is passed through to ginkgo" {
  cd "$WORK_DIR"
  export FLAKE_ATTEMPTS="2"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  has_arg "--flake-attempts=2"
}

@test "flake-attempts: 1 adds no argument (ginkgo's own default)" {
  cd "$WORK_DIR"
  export FLAKE_ATTEMPTS="1"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! has_arg "--flake-attempts=1"
}

@test "flake-attempts: unset adds no argument" {
  cd "$WORK_DIR"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(cat "$MOCK_ARGS_FILE")" != *"--flake-attempts"* ]]
}

@test "flake-attempts: a non-numeric value warns and does not reach ginkgo" {
  # Passing it through would fail the job minutes later, after suite setup,
  # instead of warning now.
  cd "$WORK_DIR"
  export FLAKE_ATTEMPTS="two"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not an integer >= 1"* ]]
  [[ "$(cat "$MOCK_ARGS_FILE")" != *"--flake-attempts"* ]]
}

@test "flake-attempts: zero warns and does not reach ginkgo" {
  cd "$WORK_DIR"
  export FLAKE_ATTEMPTS="0"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not an integer >= 1"* ]]
  [[ "$(cat "$MOCK_ARGS_FILE")" != *"--flake-attempts"* ]]
}

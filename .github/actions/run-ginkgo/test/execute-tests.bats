#!/usr/bin/env bats
# Tests for execute-tests.sh argument construction.
# Mocks `ginkgo` to capture the arguments it would receive.

SCRIPT="$BATS_TEST_DIRNAME/../src/execute-tests.sh"

setup() {
  MOCK_DIR=$(mktemp -d)
  export MOCK_ARGS_FILE="$MOCK_DIR/ginkgo-args"

  # Create a mock ginkgo that records arguments
  MOCK_BIN="$MOCK_DIR/bin"
  mkdir -p "$MOCK_BIN"
  cat > "$MOCK_BIN/ginkgo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGS_FILE"
MOCK
  chmod +x "$MOCK_BIN/ginkgo"

  # Create a fake test directory structure
  export WORK_DIR="$MOCK_DIR/workspace"
  mkdir -p "$WORK_DIR/e2e-next/suites/basic"

  # Required env vars
  export TEST_DIR="e2e-next"
  export TIMEOUT="60m"
  export PROCS="8"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

has_arg() {
  grep -qF -- "$1" "$MOCK_ARGS_FILE"
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

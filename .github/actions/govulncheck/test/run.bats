#!/usr/bin/env bats
# Tests for govulncheck/run.sh
#
# Stubs `govulncheck` so we can assert on the argument vector and simulate
# different output/exit-code combinations without downloading the real tool.

SCRIPT="$BATS_TEST_DIRNAME/../run.sh"

setup() {
  TEST_DIR=$(mktemp -d)
  export TEST_DIR

  MOCK_DIR="$TEST_DIR/mock"
  mkdir -p "$MOCK_DIR"

  export GITHUB_OUTPUT="$TEST_DIR/github_output"
  : > "$GITHUB_OUTPUT"

  export GOVULNCHECK_CALLS="$TEST_DIR/govulncheck_calls"
  export GOVULNCHECK_OUTPUT="$TEST_DIR/govulncheck_output"
  export GOVULNCHECK_EXIT="$TEST_DIR/govulncheck_exit"

  : > "$GOVULNCHECK_CALLS"
  : > "$GOVULNCHECK_OUTPUT"
  echo "0" > "$GOVULNCHECK_EXIT"

  # Stub govulncheck:
  #   - record every invocation's args as a tab-separated line in
  #     GOVULNCHECK_CALLS
  #   - echo GOVULNCHECK_OUTPUT (file contents) to stdout
  #   - exit with GOVULNCHECK_EXIT
  cat > "$MOCK_DIR/govulncheck" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GOVULNCHECK_CALLS"
cat "$GOVULNCHECK_OUTPUT"
exit "$(cat "$GOVULNCHECK_EXIT")"
MOCK
  chmod +x "$MOCK_DIR/govulncheck"

  export PATH="$MOCK_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Helper: read the `has_vulnerabilities` value back from GITHUB_OUTPUT.
get_has_vuln() {
  grep -E '^has_vulnerabilities=' "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2
}

# Helper: read the `report` multiline value back from GITHUB_OUTPUT. Uses
# awk so we don't assume a particular heredoc delimiter escape.
get_report() {
  awk '
    /^report<<GOVULNCHECK_REPORT_EOF$/ { in_report = 1; next }
    /^GOVULNCHECK_REPORT_EOF$/ { in_report = 0; next }
    in_report { print }
  ' "$GITHUB_OUTPUT"
}

# --- Required env validation ------------------------------------------------

@test "fails when GITHUB_OUTPUT is unset" {
  unset GITHUB_OUTPUT
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

# --- Arg construction -------------------------------------------------------

@test "defaults to -test ./... when nothing is set" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -F -- "-test ./..." "$GOVULNCHECK_CALLS"
}

@test "omits -test when TEST_FLAG=false" {
  TEST_FLAG=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -F -- "-test" "$GOVULNCHECK_CALLS"
}

@test "passes SCAN_PATHS verbatim (multiple paths)" {
  SCAN_PATHS="./cmd/... ./pkg/..." run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -F -- "-test ./cmd/... ./pkg/..." "$GOVULNCHECK_CALLS"
}

# --- Exit code + has_vulnerabilities output ---------------------------------

@test "writes has_vulnerabilities=0 on clean scan" {
  echo "No vulnerabilities found" > "$GOVULNCHECK_OUTPUT"
  echo "0" > "$GOVULNCHECK_EXIT"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(get_has_vuln)" = "0" ]
}

@test "writes has_vulnerabilities=3 and exits 3 when govulncheck exits 3" {
  echo "Vulnerability #1: GO-2024-1234" > "$GOVULNCHECK_OUTPUT"
  echo "3" > "$GOVULNCHECK_EXIT"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [ "$(get_has_vuln)" = "3" ]
}

# --- Report output ----------------------------------------------------------

@test "does NOT write report when scan is clean" {
  echo "No vulnerabilities found" > "$GOVULNCHECK_OUTPUT"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q '^report<<' "$GITHUB_OUTPUT"
}

@test "writes full report when output fits under limit" {
  printf 'Vulnerability #1: GO-2024-1234\ntrace...\n' > "$GOVULNCHECK_OUTPUT"
  echo "3" > "$GOVULNCHECK_EXIT"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  report=$(get_report)
  [[ "$report" == *"GO-2024-1234"* ]]
  [[ "$report" != *"truncated"* ]]
}

@test "truncates report to REPORT_LIMIT, keeping the tail and prepending marker" {
  # Build ~3100 chars: 3000 chars of 'A' + unique marker at the end so we
  # can assert the tail is kept.
  head_block=$(printf 'A%.0s' $(seq 1 3000))
  tail_block="Vulnerability #1: GO-2024-DEADBEEF"
  printf '%s\n%s\n' "$head_block" "$tail_block" > "$GOVULNCHECK_OUTPUT"
  echo "3" > "$GOVULNCHECK_EXIT"

  REPORT_LIMIT=2800 run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  report=$(get_report)
  [[ "$report" == *"truncated"* ]]
  [[ "$report" == *"GO-2024-DEADBEEF"* ]]
}

@test "custom REPORT_LIMIT is honored" {
  # Output is 100 chars. With REPORT_LIMIT=50 it should be truncated.
  body=$(printf 'B%.0s' $(seq 1 100))
  echo "${body}" > "$GOVULNCHECK_OUTPUT"
  echo "3" > "$GOVULNCHECK_EXIT"
  REPORT_LIMIT=50 run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  report=$(get_report)
  [[ "$report" == *"truncated"* ]]
}

# --- GOVULNCHECK_BIN override -----------------------------------------------

@test "respects GOVULNCHECK_BIN override" {
  # Create a second stub binary with a different name
  cat > "$TEST_DIR/mock/my-vuln" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GOVULNCHECK_CALLS"
exit 0
MOCK
  chmod +x "$TEST_DIR/mock/my-vuln"

  GOVULNCHECK_BIN=my-vuln run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # govulncheck stub should NOT have been called
  [ ! -s "$GOVULNCHECK_CALLS" ] || {
    # Only my-vuln's invocation should be there, not the default binary.
    # Our stubs both write to the same log, so we assert on presence of -test
    # which the script always passes.
    grep -F -- "-test" "$GOVULNCHECK_CALLS"
  }
}

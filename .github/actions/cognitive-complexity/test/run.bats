#!/usr/bin/env bats
# Tests for cognitive-complexity/run.sh
#
# Stubs `gocognit` so we can assert on the argument vector and simulate
# findings, a clean run and a tool error without the real binary.

SCRIPT="$BATS_TEST_DIRNAME/../run.sh"

setup() {
  TEST_DIR=$(mktemp -d)
  export TEST_DIR

  MOCK_DIR="$TEST_DIR/mock"
  mkdir -p "$MOCK_DIR"

  export GITHUB_STEP_SUMMARY="$TEST_DIR/summary"
  : > "$GITHUB_STEP_SUMMARY"
  export THRESHOLD=20

  export GOCOGNIT_CALLS="$TEST_DIR/gocognit_calls"
  export GOCOGNIT_OUTPUT="$TEST_DIR/gocognit_output"
  export GOCOGNIT_EXIT="$TEST_DIR/gocognit_exit"
  : > "$GOCOGNIT_CALLS"
  : > "$GOCOGNIT_OUTPUT"
  echo "0" > "$GOCOGNIT_EXIT"

  cat > "$MOCK_DIR/gocognit" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GOCOGNIT_CALLS"
cat "$GOCOGNIT_OUTPUT"
echo "gocognit: note: recursion may be under-counted" >&2
exit "$(cat "$GOCOGNIT_EXIT")"
MOCK
  chmod +x "$MOCK_DIR/gocognit"

  export PATH="$MOCK_DIR:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "findings: exits 0 and writes them highest first to the summary" {
  printf '%s\n' "25 pkg a a.go:1:1" "140 pkg b b.go:1:1" "31 pkg c c.go:1:1" > "$GOCOGNIT_OUTPUT"
  echo "1" > "$GOCOGNIT_EXIT"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  expected=$(printf '%s\n' \
    "### 3 functions with cognitive complexity > 20" \
    '```' \
    "140 pkg b b.go:1:1" \
    "31 pkg c c.go:1:1" \
    "25 pkg a a.go:1:1" \
    '```')
  [ "$(cat "$GITHUB_STEP_SUMMARY")" = "$expected" ]
}

@test "no findings: writes a zero count without a code block" {
  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_STEP_SUMMARY")" = "### 0 functions with cognitive complexity > 20" ]
}

@test "tool error: fails the step when gocognit exits non-zero with no findings" {
  echo "1" > "$GOCOGNIT_EXIT"

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::gocognit failed"* ]]
}

@test "passes threshold, ignore and every scan path to gocognit" {
  export IGNORE='_test\.go$'
  export SCAN_PATHS="./cmd ./pkg"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(cat "$GOCOGNIT_CALLS")" = '-over 20 -ignore _test\.go$ ./cmd ./pkg' ]
}

@test "requires THRESHOLD" {
  unset THRESHOLD

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"THRESHOLD is required"* ]]
}

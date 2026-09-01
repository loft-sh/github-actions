#!/usr/bin/env bats
# End-to-end wiring: resolve-rerun-focus.sh emits the focus as a step output, the runner
# maps it onto GINKGO_FOCUS via action.yml, and execute-tests.sh must hand it to ginkgo.
# The two scripts run as separate composite steps, so nothing else covers the seam.

load helpers

RESOLVE="$BATS_TEST_DIRNAME/../src/resolve-rerun-focus.sh"
EXECUTE="$BATS_TEST_DIRNAME/../src/execute-tests.sh"
SUMMARY="$BATS_TEST_DIRNAME/../src/generate-summary.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/rerun"

setup() {
  MOCK_DIR=$(mktemp -d)
  setup_github_output
  setup_ginkgo_mock e2e
  export GINKGO_LABEL="pr"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# Reads the focus step output the way action.yml wires it into the execute step.
export_resolved_focus() {
  local value
  value="$(sed -n '/^focus<<GINKGO_FOCUS_EOF$/,/^GINKGO_FOCUS_EOF$/{ /GINKGO_FOCUS_EOF$/d; p; }' "$GITHUB_OUTPUT")"
  export GINKGO_FOCUS="$value"
}

@test "a resolved focus reaches ginkgo intact as a single argument" {
  RERUN_FAILED_ONLY=true GITHUB_RUN_ATTEMPT=2 RERUN_REPORTS_DIR="$FIXTURES/mixed-failures" \
    bash "$RESOLVE"
  export_resolved_focus
  [ -n "$GINKGO_FOCUS" ]

  cd "$WORK_DIR"
  run bash "$EXECUTE"
  [ "$status" -eq 0 ]

  # Byte-identical to what was resolved - no shell mangling of $, (, | or backslashes
  grep -qxF -- "--focus=$GINKGO_FOCUS" "$MOCK_ARGS_FILE"
  grep -qxF -- "--label-filter=pr" "$MOCK_ARGS_FILE"
}

@test "no --focus reaches ginkgo when the resolve step falls back to a full run" {
  RERUN_FAILED_ONLY=true GITHUB_RUN_ATTEMPT=2 RERUN_REPORTS_DIR="$FIXTURES/all-passed" \
    bash "$RESOLVE"
  export_resolved_focus
  [ -z "$GINKGO_FOCUS" ]

  cd "$WORK_DIR"
  run bash "$EXECUTE"
  [ "$status" -eq 0 ]
  # Positive half: `! grep` also succeeds on a file the mock never wrote, so
  # without this "no --focus was passed" and "ginkgo never ran" look identical.
  grep -qxF -- "--label-filter=pr" "$MOCK_ARGS_FILE"
  ! grep -q -- '--focus=' "$MOCK_ARGS_FILE"
}

# --- the zero-match guard ---

@test "a focused rerun that matched no specs fails instead of reporting success" {
  mkdir -p "$WORK_DIR/test-reports"
  echo '[{"PreRunStats":{"TotalSpecs":40,"SpecsThatWillRun":0},"RunTime":0,"SpecReports":[]}]' \
    >"$WORK_DIR/test-reports/report.json"

  cd "$WORK_DIR"
  REPORT_FILE=test-reports/report.json FOCUSED_RERUN=true run bash "$SUMMARY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"matched no specs"* ]]
}

@test "an unfocused run with no specs is left alone" {
  mkdir -p "$WORK_DIR/test-reports"
  echo '[{"PreRunStats":{"TotalSpecs":40,"SpecsThatWillRun":0},"RunTime":0,"SpecReports":[]}]' \
    >"$WORK_DIR/test-reports/report.json"

  cd "$WORK_DIR"
  REPORT_FILE=test-reports/report.json FOCUSED_RERUN=false run bash "$SUMMARY"
  [ "$status" -eq 0 ]
}

@test "a focused rerun that did run specs is not flagged" {
  mkdir -p "$WORK_DIR/test-reports"
  cp "$FIXTURES/../with-failures.json" "$WORK_DIR/test-reports/report.json"

  cd "$WORK_DIR"
  REPORT_FILE=test-reports/report.json FOCUSED_RERUN=true run bash "$SUMMARY"
  [ "$status" -eq 0 ]
}

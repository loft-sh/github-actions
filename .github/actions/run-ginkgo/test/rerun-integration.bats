#!/usr/bin/env bats
# End-to-end wiring: resolve-rerun-focus.sh exports GINKGO_FOCUS via GITHUB_ENV, the
# runner turns that into an env var, and execute-tests.sh must hand it to ginkgo.
# The two scripts run as separate composite steps, so nothing else covers the seam.

RESOLVE="$BATS_TEST_DIRNAME/../src/resolve-rerun-focus.sh"
EXECUTE="$BATS_TEST_DIRNAME/../src/execute-tests.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/rerun"

setup() {
  MOCK_DIR=$(mktemp -d)
  export GITHUB_ENV="$MOCK_DIR/env"
  export GITHUB_OUTPUT="$MOCK_DIR/output"
  touch "$GITHUB_ENV" "$GITHUB_OUTPUT"

  MOCK_BIN="$MOCK_DIR/bin"
  mkdir -p "$MOCK_BIN"
  export MOCK_ARGS_FILE="$MOCK_DIR/ginkgo-args"
  cat >"$MOCK_BIN/ginkgo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGS_FILE"
MOCK
  chmod +x "$MOCK_BIN/ginkgo"
  export PATH="$MOCK_BIN:$PATH"

  export WORK_DIR="$MOCK_DIR/workspace"
  mkdir -p "$WORK_DIR/e2e"
  export TEST_DIR="e2e"
  export TIMEOUT="60m"
  export PROCS="8"
  export GINKGO_LABEL="pr"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# Applies GITHUB_ENV the way the Actions runner does between steps.
export_github_env() {
  local key value
  while IFS= read -r line; do
    case "$line" in
      *"<<GINKGO_FOCUS_EOF") key="${line%%<<*}"; IFS= read -r value; export "$key=$value" ;;
    esac
  done <"$GITHUB_ENV"
}

@test "a resolved focus reaches ginkgo intact through GITHUB_ENV" {
  RERUN_FAILED_ONLY=true GITHUB_RUN_ATTEMPT=2 RERUN_REPORTS_DIR="$FIXTURES/mixed-failures" \
    bash "$RESOLVE"
  export_github_env
  [ -n "$GINKGO_FOCUS" ]

  cd "$WORK_DIR"
  run bash "$EXECUTE"
  [ "$status" -eq 0 ]

  # One argument, byte-identical to what was resolved - no shell mangling of $, (, |
  grep -qxF -- "--focus=$GINKGO_FOCUS" "$MOCK_ARGS_FILE"
  grep -qxF -- "--label-filter=pr" "$MOCK_ARGS_FILE"
}

@test "no --focus reaches ginkgo when the resolve step falls back to a full run" {
  RERUN_FAILED_ONLY=true GITHUB_RUN_ATTEMPT=2 RERUN_REPORTS_DIR="$FIXTURES/all-passed" \
    bash "$RESOLVE"
  export_github_env
  [ -z "${GINKGO_FOCUS:-}" ]

  cd "$WORK_DIR"
  run bash "$EXECUTE"
  [ "$status" -eq 0 ]
  ! grep -q -- '--focus=' "$MOCK_ARGS_FILE"
}

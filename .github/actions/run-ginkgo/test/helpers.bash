#!/usr/bin/env bash
# Shared bats scaffolding for the run-ginkgo suites.

# Puts a fake ginkgo on PATH that records its argv in $MOCK_ARGS_FILE, and sets the env
# vars execute-tests.sh requires. Expects $MOCK_DIR to exist.
# shellcheck disable=SC2153  # MOCK_DIR is set by each suite's setup()
setup_ginkgo_mock() {
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
  mkdir -p "$WORK_DIR/${1:-e2e-next}/suites/basic"
  export TEST_DIR="${1:-e2e-next}"
  export TIMEOUT="60m"
  export PROCS="8"
}

# Stubs the runner's $GITHUB_OUTPUT file. Expects $MOCK_DIR to exist.
setup_github_output() {
  export GITHUB_OUTPUT="$MOCK_DIR/output"
  : >"$GITHUB_OUTPUT"
}

has_arg() {
  grep -qF -- "$1" "$MOCK_ARGS_FILE"
}

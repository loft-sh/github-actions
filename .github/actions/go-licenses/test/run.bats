#!/usr/bin/env bats
# Tests for run.sh
#
# Stubs `go-licenses` and `go` so we can assert on the argument vector the
# script builds without needing a real Go toolchain or real Go sources.

SCRIPT="$BATS_TEST_DIRNAME/../run.sh"

setup() {
  MOCK_DIR=$(mktemp -d)
  export MOCK_DIR
  export GO_LICENSES_ARGS_FILE="$MOCK_DIR/go_licenses_args"
  export GO_LICENSES_EXIT_CODE_FILE="$MOCK_DIR/go_licenses_exit_code"
  export GO_LICENSES_STDOUT_FILE="$MOCK_DIR/go_licenses_stdout"
  export GO_WORK_JSON_FILE="$MOCK_DIR/go_work_json"

  echo "0" > "$GO_LICENSES_EXIT_CODE_FILE"
  : > "$GO_LICENSES_STDOUT_FILE"

  # Stub go-licenses: record its arguments, optionally emit stdout, exit with
  # the configured exit code.
  cat > "$MOCK_DIR/go-licenses" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GO_LICENSES_ARGS_FILE"
if [ -s "$GO_LICENSES_STDOUT_FILE" ]; then
  cat "$GO_LICENSES_STDOUT_FILE"
fi
exit "$(cat "$GO_LICENSES_EXIT_CODE_FILE")"
MOCK
  chmod +x "$MOCK_DIR/go-licenses"

  # Stub `go` so `go work edit -json` returns a fixture. Any other `go`
  # invocation fails loudly — the script should not call `go` outside the
  # go-work mode path.
  cat > "$MOCK_DIR/go" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "work" ] && [ "$2" = "edit" ] && [ "$3" = "-json" ]; then
  cat "$GO_WORK_JSON_FILE"
  exit 0
fi
echo "unexpected go invocation: $*" >&2
exit 99
MOCK
  chmod +x "$MOCK_DIR/go"

  export PATH="$MOCK_DIR:$PATH"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# --- Subcommand / PACKAGE_MODE validation ---

@test "fails when subcommand is missing" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails on invalid subcommand" {
  run bash "$SCRIPT" invalid
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid subcommand"* ]]
}

@test "fails on invalid PACKAGE_MODE" {
  PACKAGE_MODE=bogus run bash "$SCRIPT" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid PACKAGE_MODE"* ]]
}

# --- Mode: all (./... + --ignore) ---

@test "all mode with no ignores passes ./..." {
  run bash "$SCRIPT" check
  [ "$status" -eq 0 ]
  [ "$(cat "$GO_LICENSES_ARGS_FILE")" = "check
./..." ]
}

@test "all mode appends --ignore for each comma-separated prefix" {
  IGNORED_PACKAGES="github.com/loft-sh,modernc.org/mathutil" \
    run bash "$SCRIPT" check
  [ "$status" -eq 0 ]
  [ "$(cat "$GO_LICENSES_ARGS_FILE")" = "check
./...
--ignore
github.com/loft-sh
--ignore
modernc.org/mathutil" ]
}

@test "all mode trims whitespace and drops empty entries" {
  IGNORED_PACKAGES=" github.com/loft-sh , , modernc.org/mathutil " \
    run bash "$SCRIPT" check
  [ "$status" -eq 0 ]
  [ "$(cat "$GO_LICENSES_ARGS_FILE")" = "check
./...
--ignore
github.com/loft-sh
--ignore
modernc.org/mathutil" ]
}

# --- Mode: go-work (enumerate + filter) ---

@test "go-work mode enumerates DiskPaths from go.work" {
  cat > "$GO_WORK_JSON_FILE" <<'JSON'
{"Use":[{"DiskPath":"."},{"DiskPath":"staging/src/github.com/loft-sh/api"}]}
JSON
  PACKAGE_MODE=go-work run bash "$SCRIPT" check
  [ "$status" -eq 0 ]
  [ "$(cat "$GO_LICENSES_ARGS_FILE")" = "check
./...
staging/src/github.com/loft-sh/api/..." ]
}

@test "go-work mode filters out DiskPaths matching ignored prefixes" {
  cat > "$GO_WORK_JSON_FILE" <<'JSON'
{"Use":[{"DiskPath":"."},{"DiskPath":"staging/src/github.com/loft-sh/api"},{"DiskPath":"staging/src/github.com/loft-sh/agentapi"}]}
JSON
  PACKAGE_MODE=go-work \
    IGNORED_PACKAGES="github.com/loft-sh" \
    run bash "$SCRIPT" check
  [ "$status" -eq 0 ]
  [ "$(cat "$GO_LICENSES_ARGS_FILE")" = "check
./..." ]
}

@test "go-work mode fails when all packages are filtered out" {
  cat > "$GO_WORK_JSON_FILE" <<'JSON'
{"Use":[{"DiskPath":"staging/src/github.com/loft-sh/api"}]}
JSON
  PACKAGE_MODE=go-work \
    IGNORED_PACKAGES="github.com/loft-sh" \
    run bash "$SCRIPT" check
  [ "$status" -ne 0 ]
  [[ "$output" == *"no packages to check"* ]]
}

# --- Check subcommand: fail-on-error ---

@test "check fails when go-licenses exits non-zero and fail-on-error=true" {
  echo "1" > "$GO_LICENSES_EXIT_CODE_FILE"
  run bash "$SCRIPT" check
  [ "$status" -ne 0 ]
}

@test "check succeeds with warning when fail-on-error=false" {
  echo "1" > "$GO_LICENSES_EXIT_CODE_FILE"
  FAIL_ON_ERROR=false run bash "$SCRIPT" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"fail-on-error=false"* ]]
}

@test "check succeeds silently when go-licenses exits zero" {
  run bash "$SCRIPT" check
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning::"* ]]
}

# --- Report subcommand ---

@test "report requires TEMPLATE_PATH" {
  OUTPUT_PATH="$MOCK_DIR/out.mdx" run bash "$SCRIPT" report
  [ "$status" -ne 0 ]
  [[ "$output" == *"TEMPLATE_PATH"* ]]
}

@test "report requires OUTPUT_PATH" {
  TEMPLATE_PATH="$MOCK_DIR/tpl.tmpl" run bash "$SCRIPT" report
  [ "$status" -ne 0 ]
  [[ "$output" == *"OUTPUT_PATH"* ]]
}

@test "report writes go-licenses stdout to OUTPUT_PATH" {
  echo "rendered licenses" > "$GO_LICENSES_STDOUT_FILE"
  touch "$MOCK_DIR/tpl.tmpl"
  TEMPLATE_PATH="$MOCK_DIR/tpl.tmpl" \
    OUTPUT_PATH="$MOCK_DIR/nested/dir/out.mdx" \
    run bash "$SCRIPT" report
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_DIR/nested/dir/out.mdx")" = "rendered licenses" ]
}

@test "report passes report subcommand and template path to go-licenses" {
  touch "$MOCK_DIR/tpl.tmpl"
  TEMPLATE_PATH="$MOCK_DIR/tpl.tmpl" \
    OUTPUT_PATH="$MOCK_DIR/out.mdx" \
    IGNORED_PACKAGES="github.com/loft-sh" \
    run bash "$SCRIPT" report
  [ "$status" -eq 0 ]
  [ "$(cat "$GO_LICENSES_ARGS_FILE")" = "report
--template
$MOCK_DIR/tpl.tmpl
./...
--ignore
github.com/loft-sh" ]
}

@test "report works in go-work mode" {
  cat > "$GO_WORK_JSON_FILE" <<'JSON'
{"Use":[{"DiskPath":"."},{"DiskPath":"staging/src/github.com/loft-sh/api"}]}
JSON
  echo "rendered" > "$GO_LICENSES_STDOUT_FILE"
  touch "$MOCK_DIR/tpl.tmpl"
  PACKAGE_MODE=go-work \
    IGNORED_PACKAGES="github.com/loft-sh" \
    TEMPLATE_PATH="$MOCK_DIR/tpl.tmpl" \
    OUTPUT_PATH="$MOCK_DIR/out.mdx" \
    run bash "$SCRIPT" report
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_DIR/out.mdx")" = "rendered" ]
  [ "$(cat "$GO_LICENSES_ARGS_FILE")" = "report
--template
$MOCK_DIR/tpl.tmpl
./..." ]
}

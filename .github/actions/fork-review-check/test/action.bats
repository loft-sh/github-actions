#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/action.sh"

setup() {
  MOCK_DIR=$(mktemp -d)
  export MOCK_DIR
  export GITHUB_OUTPUT="$MOCK_DIR/github_output"
  export FORK_REVIEW_CHECK_BIN="$MOCK_DIR/fork-review-check"
  export ARGS_FILE="$MOCK_DIR/args"
  export INPUT_MODE=scan
  export INPUT_ROOT=target
  export INPUT_DIRS=$' cmd/api \ncmd/worker'
  export INPUT_IMAGES='ghcr.io/loft-sh/kine:v0.16.5.vcluster.1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  export INPUT_BINARIES='https://github.com/loft-sh/kine/releases/download/v0.16.5.vcluster.1/kine bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  export INPUT_SOURCES='loft-sh/kine=v0.16.5.vcluster.1'
  export INPUT_SIGNER_WORKFLOWS='loft-sh/kine=.github/workflows/release.yml'
  export INPUT_UPSTREAMS='loft-sh/kine=k3s-io/kine'
  export INPUT_AS_OF='2026-10-27T09:00:00Z'
  export INPUT_ADVISORY=true
  export INPUT_RECEIPT="$MOCK_DIR/receipt.json"

  cat > "$FORK_REVIEW_CHECK_BIN" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$ARGS_FILE"
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-receipt" ]; then
    next=$((i + 1))
    printf '{"pass":true}\n' > "${!next}"
  fi
done
MOCK
  chmod +x "$FORK_REVIEW_CHECK_BIN"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

@test "passes every supported input as an argument" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(cat "$ARGS_FILE")" = "scan
-root
target
-receipt
$MOCK_DIR/receipt.json
-advisory=true
-dir
cmd/api
-dir
cmd/worker
-image
ghcr.io/loft-sh/kine:v0.16.5.vcluster.1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-source
loft-sh/kine=v0.16.5.vcluster.1
-signer-workflow
loft-sh/kine=.github/workflows/release.yml
-upstream
loft-sh/kine=k3s-io/kine
-as-of
2026-10-27T09:00:00Z
-url
https://github.com/loft-sh/kine/releases/download/v0.16.5.vcluster.1/kine
-sha256
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
  [ "$(cat "$GITHUB_OUTPUT")" = "receipt=$MOCK_DIR/receipt.json
pass=true" ]
}

@test "writes outputs and passes the exit code through on a rule failure" {
  cat > "$FORK_REVIEW_CHECK_BIN" <<'MOCK'
#!/usr/bin/env bash
printf '{"pass":false}\n' > "$INPUT_RECEIPT"
exit 1
MOCK
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(cat "$GITHUB_OUTPUT")" = "receipt=$MOCK_DIR/receipt.json
pass=false" ]
}

@test "skips outputs when the check cannot run" {
  printf '#!/usr/bin/env bash\nexit 2\n' > "$FORK_REVIEW_CHECK_BIN"
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "rejects malformed binary input" {
  INPUT_BINARIES='https://github.com/loft-sh/kine/releases/download/v0.16.5.vcluster.1/kine' \
    run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"binaries entries must be <url> <sha256>"* ]]
}

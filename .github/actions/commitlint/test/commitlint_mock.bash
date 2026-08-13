# Mocks for the external commands action.sh shells out to.
#
# Each mock is a real executable on PATH, so the script under test runs as a
# child process with faithful `set -e` semantics rather than being sourced into
# the harness.
#
# Behaviour is driven by env vars the tests set:
#   COMMITLINT_MOCK_EXIT          exit code for every commitlint invocation
#   COMMITLINT_MOCK_TITLE_EXIT    exit code when linting a message on stdin
#   COMMITLINT_MOCK_RANGE_EXIT    exit code when linting a --from/--to range
#   COMMITLINT_MOCK_VERSION_EXIT  exit code for the --version probe
#   COMMITLINT_MOCK_STDOUT        text the mock prints on stdout
#   NPM_MOCK_STDOUT               text the npm mock prints on stdout
#   NPM_MOCK_FAIL                 non-empty makes `npm ci` / `npm install` fail
#
# Every invocation is appended to $CALL_LOG, one line per call, so tests can
# assert on which binary ran and with which arguments.

setup_mocks() {
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$MOCK_BIN"
  : >"$CALL_LOG"
  export MOCK_BIN CALL_LOG
  export PATH="$MOCK_BIN:$PATH"

  _write_commitlint "$MOCK_BIN/commitlint"

  cat >"$MOCK_BIN/npx" <<'EOF'
#!/usr/bin/env bash
echo "npx $*" >>"$CALL_LOG"
# Drop the leading `--yes @commitlint/cli@<version>` so the remaining argv
# matches what a locally installed binary would receive.
shift 2 2>/dev/null || true
exec commitlint "$@"
EOF
  chmod +x "$MOCK_BIN/npx"

  cat >"$MOCK_BIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >>"$CALL_LOG"
if [ -n "${NPM_MOCK_STDOUT:-}" ]; then
  printf '%s\n' "$NPM_MOCK_STDOUT"
fi
if [ -n "${NPM_MOCK_FAIL:-}" ]; then
  echo "npm mock: forced failure" >&2
  exit 1
fi
# Materialise the binary the real npm would have installed.
mkdir -p node_modules/.bin
cp "$MOCK_BIN/commitlint" node_modules/.bin/commitlint
EOF
  chmod +x "$MOCK_BIN/npm"
}

# A commitlint stand-in that records its argv and honours the *_EXIT vars.
_write_commitlint() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "commitlint $*" >>"$CALL_LOG"

# The action smoke-tests the binary before linting anything. Answering here
# without touching stdin keeps that probe separate from the lint calls.
for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    if [ -n "${COMMITLINT_MOCK_VERSION_EXIT:-}" ]; then
      exit "$COMMITLINT_MOCK_VERSION_EXIT"
    fi
    echo "19.8.1"
    exit 0
  fi
done

is_range=false
for arg in "$@"; do
  if [ "$arg" = "--from" ]; then
    is_range=true
    break
  fi
done

if [ "$is_range" = true ]; then
  if [ -n "${COMMITLINT_MOCK_STDOUT:-}" ]; then
    printf '%s\n' "$COMMITLINT_MOCK_STDOUT"
  fi
  exit "${COMMITLINT_MOCK_RANGE_EXIT:-${COMMITLINT_MOCK_EXIT:-0}}"
fi

cat >/dev/null   # drain the message on stdin
if [ -n "${COMMITLINT_MOCK_STDOUT:-}" ]; then
  printf '%s\n' "$COMMITLINT_MOCK_STDOUT"
fi
exit "${COMMITLINT_MOCK_TITLE_EXIT:-${COMMITLINT_MOCK_EXIT:-0}}"
EOF
  chmod +x "$1"
}

# Installs a local node_modules/.bin/commitlint in the current directory, as a
# repository that has already run `npm ci` would have.
install_local_commitlint() {
  mkdir -p node_modules/.bin
  _write_commitlint node_modules/.bin/commitlint
}

# The same, except the binary also appends to $GITHUB_OUTPUT, which it inherits
# like any other child. This is what a compromised dependency in the calling
# repository's own lockfile can do, so every output the script writes has to
# land after it or the runner resolves the forged value instead.
install_output_forging_commitlint() {
  mkdir -p node_modules/.bin
  cat >node_modules/.bin/commitlint <<'EOF'
#!/usr/bin/env bash
echo "commitlint $*" >>"$CALL_LOG"
for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    echo "19.8.1"
    exit 0
  fi
done
cat >/dev/null
printf 'skipped=true\n' >>"$GITHUB_OUTPUT"
exit "${COMMITLINT_MOCK_TITLE_EXIT:-0}"
EOF
  chmod +x node_modules/.bin/commitlint
}

calls() { cat "$CALL_LOG"; }

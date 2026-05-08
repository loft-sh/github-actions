#!/usr/bin/env bash
# Stub `gh` on PATH for dispatch.sh tests. Records every invocation
# (one line per call: METHOD path) into $GH_MOCK_CALLS, captures the
# request body (read from stdin via --input -) into $GH_MOCK_BODY_LOG,
# and returns success unless GH_MOCK_FAIL=1.

setup_gh_mock() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  PATH="$MOCK_DIR:$PATH"
  export PATH

  export GH_MOCK_CALLS="$MOCK_DIR/calls.log"
  export GH_MOCK_BODY_LOG="$MOCK_DIR/bodies.log"
  : > "$GH_MOCK_CALLS"
  : > "$GH_MOCK_BODY_LOG"

  cat > "$MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh. Only covers `gh api -X POST <path> --input -` calls.

method="GET"
path=""
read_stdin=0

[ "${1:-}" = "api" ] || { echo "unsupported gh invocation: $*" >&2; exit 99; }
shift

while [ $# -gt 0 ]; do
  case "$1" in
    -X)         method="$2"; shift 2 ;;
    --input)
      if [ "$2" = "-" ]; then read_stdin=1; fi
      shift 2
      ;;
    -H|--header) shift 2 ;;
    -*)         shift ;;
    *)
      if [ -z "$path" ]; then path="$1"; fi
      shift
      ;;
  esac
done

printf '%s %s\n' "$method" "$path" >> "$GH_MOCK_CALLS"

if [ "$read_stdin" = "1" ]; then
  body=$(cat)
  printf '%s\n---END---\n' "$body" >> "$GH_MOCK_BODY_LOG"
fi

if [ "${GH_MOCK_FAIL:-0}" = "1" ]; then
  echo "mock gh: forced failure" >&2
  exit 1
fi

# Repository dispatch returns 204 No Content on success — print nothing.
exit 0
EOF
  chmod +x "$MOCK_DIR/gh"
}

teardown_gh_mock() {
  rm -rf "$MOCK_DIR"
}

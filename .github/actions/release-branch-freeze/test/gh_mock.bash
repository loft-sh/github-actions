#!/usr/bin/env bash
# Stub `gh` on PATH for freeze.sh tests. Records every invocation as
# "METHOD path" into $GH_MOCK_CALLS, captures request bodies (read from
# --input -) into $GH_MOCK_BODY_LOG, records -f/--field key=value pairs into
# $GH_MOCK_FIELD_LOG, and returns fixtures:
#   GET  .../rulesets        -> $GH_MOCK_RULESETS (default "[]")
#   POST .../rulesets        -> {"id": $GH_MOCK_NEW_ID} (default 12345)
#   PUT  .../rulesets/<id>    -> {}
# Knobs:
#   GH_MOCK_FAIL=1        force a non-zero exit on every call.
#   GH_MOCK_FAIL_WRITE=1  force a non-zero exit on write calls (POST/PUT/PATCH)
#                         only, so a GET (find_ruleset_id) still succeeds.
#   GH_MOCK_POST_NO_ID=1  POST returns {} (a 2xx body without an id field).

setup_gh_mock() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  PATH="$MOCK_DIR:$PATH"
  export PATH

  export GH_MOCK_CALLS="$MOCK_DIR/calls.log"
  export GH_MOCK_BODY_LOG="$MOCK_DIR/bodies.log"
  export GH_MOCK_FIELD_LOG="$MOCK_DIR/fields.log"
  : > "$GH_MOCK_CALLS"
  : > "$GH_MOCK_BODY_LOG"
  : > "$GH_MOCK_FIELD_LOG"
  export GH_MOCK_RULESETS='[]'
  export GH_MOCK_NEW_ID='12345'

  cat > "$MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh. Covers `gh api [-X METHOD] <path> [--input -] [-f k=v]`.
[ "${1:-}" = "api" ] || { echo "unsupported gh invocation: $*" >&2; exit 99; }
shift

method="GET"
path=""
read_stdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method)              method="$2"; shift 2 ;;
    --input)                  [ "$2" = "-" ] && read_stdin=1; shift 2 ;;
    -f|--raw-field|--field)   printf '%s\n' "$2" >> "$GH_MOCK_FIELD_LOG"; shift 2 ;;
    -H|--header)              shift 2 ;;
    --jq|-q)                  shift 2 ;;
    -*)                       shift ;;
    *)                        [ -z "$path" ] && path="$1"; shift ;;
  esac
done

printf '%s %s\n' "$method" "$path" >> "$GH_MOCK_CALLS"
if [ "$read_stdin" = "1" ]; then
  printf '%s\n---END---\n' "$(cat)" >> "$GH_MOCK_BODY_LOG"
fi

if [ "${GH_MOCK_FAIL:-0}" = "1" ]; then
  echo "mock gh: forced failure" >&2
  exit 1
fi
if [ "${GH_MOCK_FAIL_WRITE:-0}" = "1" ] && [ "$method" != "GET" ]; then
  echo "mock gh: forced write failure ($method)" >&2
  exit 1
fi

case "$method $path" in
  "GET "*/rulesets)   printf '%s' "$GH_MOCK_RULESETS" ;;
  "POST "*/rulesets)
    if [ "${GH_MOCK_POST_NO_ID:-0}" = "1" ]; then printf '{}'; else printf '{"id": %s}' "$GH_MOCK_NEW_ID"; fi ;;
  *)                  printf '{}' ;;
esac
exit 0
EOF
  chmod +x "$MOCK_DIR/gh"
}

teardown_gh_mock() {
  rm -rf "$MOCK_DIR"
}

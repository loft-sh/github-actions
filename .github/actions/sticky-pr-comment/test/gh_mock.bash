#!/usr/bin/env bash
# Stub `gh` on PATH for upsert-comment.sh tests. Records every invocation
# (one line per call: subcommand + flags as space-joined args) into
# $GH_MOCK_CALLS, and serves canned responses based on env vars.
#
# GH_MOCK_LIST_JSON   → JSON array returned for "gh api .../issues/N/comments"
# GH_MOCK_CREATE_JSON → JSON object returned for "gh api -X POST .../comments"
# GH_MOCK_PATCH_JSON  → JSON object returned for "gh api -X PATCH .../comments/<id>" (default "{}")
# GH_MOCK_BODY_LOG    → path; the request body (-f body=...) of every PATCH/POST call is appended

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
# Mock gh. Only covers `gh api` calls used by upsert-comment.sh.

method="GET"
path=""
jq_filter=""
body=""
paginate=0

[ "${1:-}" = "api" ] || { echo "unsupported gh invocation: $*" >&2; exit 99; }
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --jq)        jq_filter="$2"; shift 2 ;;
    --paginate)  paginate=1; shift ;;
    -X)          method="$2"; shift 2 ;;
    -f)
      case "$2" in
        body=*) body="${2#body=}" ;;
      esac
      shift 2
      ;;
    -H|--header) shift 2 ;;
    -*)          shift ;;
    *)
      if [ -z "$path" ]; then path="$1"; fi
      shift
      ;;
  esac
done

# Record the call (method + path + indicator flags). Body is logged separately.
{
  printf '%s %s' "$method" "$path"
  [ -n "$jq_filter" ] && printf ' --jq=%s' "$jq_filter"
  [ "$paginate" = "1" ]   && printf ' --paginate'
  printf '\n'
} >> "$GH_MOCK_CALLS"

if [ -n "$body" ]; then
  printf '%s\n---END---\n' "$body" >> "$GH_MOCK_BODY_LOG"
fi

emit_response() {
  case "$method:$path" in
    GET:*"/issues/"*"/comments")
      printf '%s\n' "${GH_MOCK_LIST_JSON-[]}"
      ;;
    POST:*"/issues/"*"/comments")
      default_create='{"id":0}'
      printf '%s\n' "${GH_MOCK_CREATE_JSON-$default_create}"
      ;;
    PATCH:*"/issues/comments/"*)
      default_patch='{}'
      printf '%s\n' "${GH_MOCK_PATCH_JSON-$default_patch}"
      ;;
    *)
      printf '{}\n'
      ;;
  esac
}

if [ -n "$jq_filter" ]; then
  emit_response | jq -r "$jq_filter"
else
  emit_response
fi
EOF
  chmod +x "$MOCK_DIR/gh"
}

teardown_gh_mock() {
  rm -rf "$MOCK_DIR"
}

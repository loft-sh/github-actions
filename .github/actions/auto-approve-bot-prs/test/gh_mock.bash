#!/usr/bin/env bash
# Shared helper: install a stub `gh` on PATH that dispatches by first argument.
# Call setup_gh_mock first; set GH_MOCK_* env vars to control responses.

setup_gh_mock() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  PATH="$MOCK_DIR:$PATH"
  export PATH

  cat > "$MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
# Mock `gh`. Only covers the subset used by auto-approve scripts.
#
# GH_MOCK_MERGEABLE          → response for `gh api ...pulls/N`
# GH_MOCK_APPROVER           → response for `gh api user`
# GH_MOCK_CHECK_RUNS_JSON    → response for `gh api .../check-runs` (full object)
# GH_MOCK_STATUSES_JSON      → response for `gh api .../status` (combined status)
# GH_MOCK_PR_MERGE_EXIT      → exit code for `gh pr merge`
# GH_MOCK_PR_MERGE_OUT       → stdout for `gh pr merge`
# GH_MOCK_CALLS              → path; each invocation appends one line of args

[ -n "${GH_MOCK_CALLS:-}" ] && printf '%s\n' "$*" >> "$GH_MOCK_CALLS"

# Emit the raw response that matches the api path, then apply --jq/--paginate
# like real gh does, so callers see exactly what they'd see in production.
emit_api_response() {
  local path="$1" default_runs='{"check_runs":[]}' default_statuses='{"state":"success","statuses":[]}'
  case "$path" in
    user)
      printf '{"login":"%s"}\n' "${GH_MOCK_APPROVER:-}"
      ;;
    *"/pulls/"*)
      local m="${GH_MOCK_MERGEABLE:-null}"
      case "$m" in true|false) ;; *) m=null ;; esac
      printf '{"mergeable":%s}\n' "$m"
      ;;
    *"/check-runs"*)
      printf '%s\n' "${GH_MOCK_CHECK_RUNS_JSON:-$default_runs}"
      ;;
    *"/status"*)
      # Trailing /status (combined) — must come after /check-runs because
      # /check-runs also happens to contain "/runs/" but not "/status".
      printf '%s\n' "${GH_MOCK_STATUSES_JSON:-$default_statuses}"
      ;;
    *) printf '{}\n' ;;
  esac
}

apply_filter() {
  local filter="$1"
  if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi
}

case "${1:-}" in
  api)
    shift
    path="${1:-}"; shift || true
    jq_filter=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) jq_filter="$2"; shift 2 ;;
        --paginate|--method|--header|-H|-X) shift 2>/dev/null || true ;;
        *) shift ;;
      esac
    done
    emit_api_response "$path" | apply_filter "$jq_filter"
    ;;
  pr)
    shift
    case "${1:-}" in
      merge)
        echo "${GH_MOCK_PR_MERGE_OUT:-enabled}"
        exit "${GH_MOCK_PR_MERGE_EXIT:-0}"
        ;;
      *) echo "unsupported gh pr subcommand: $*" >&2; exit 99 ;;
    esac
    ;;
  *) echo "unsupported gh invocation: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$MOCK_DIR/gh"

  export GH_MOCK_CALLS="$MOCK_DIR/calls.log"
  : > "$GH_MOCK_CALLS"
}

teardown_gh_mock() {
  rm -rf "$MOCK_DIR"
}

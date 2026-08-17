#!/usr/bin/env bash
# Shared helper: install a stub `gh` on PATH for the comment-triggered-check scripts.
# Same shape as auto-approve-bot-prs/test/gh_mock.bash: dispatch on the api
# path, control responses with env vars, record every call.
#
# Only success and failure are modelled, matching the scripts, which use plain
# `gh api` and distinguish "the API answered" from "we have no idea" rather than
# branching on HTTP status.
#
# Controls, all optional:
#   GH_MOCK_PR_JSON      body for .../pulls/N
#   GH_MOCK_PR_FAIL      non-empty → the pulls call fails
#   GH_MOCK_CREATE_JSON  body for POST .../check-runs
#   GH_MOCK_CREATE_FAIL  non-empty → the create call fails
#   GH_MOCK_PATCH_FAIL   non-empty → a PATCH fails
#   GH_MOCK_CALLS        path; each invocation appends one line of args

setup_gh_mock() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  PATH="$MOCK_DIR:$PATH"
  export PATH

  cat > "$MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -o pipefail

[ -n "${GH_MOCK_CALLS:-}" ] && printf '%s\n' "$*" >> "$GH_MOCK_CALLS"

all="$*"

# Defaults are assigned, never inlined into "${VAR:-...}": a JSON literal inside
# a parameter-expansion default loses its double quotes and keeps any single
# quotes, which produces a body jq cannot parse.
default_pr='{"head":{"sha":"abc123","repo":{"full_name":"loft-sh/demo"}},"base":{"ref":"main"},"state":"open"}'
default_create='{"id":4242}'

case "$all" in
  *"--method POST"*"check-runs"*)
    [ -n "${GH_MOCK_CREATE_FAIL:-}" ] && { echo "mock: create failed" >&2; exit 1; }
    printf '%s\n' "${GH_MOCK_CREATE_JSON:-$default_create}"
    ;;
  *"--method PATCH"*)
    [ -n "${GH_MOCK_PATCH_FAIL:-}" ] && { echo "mock: patch failed" >&2; exit 1; }
    printf '{}\n'
    ;;
  *"/pulls/"*)
    [ -n "${GH_MOCK_PR_FAIL:-}" ] && { echo "mock: pulls failed" >&2; exit 1; }
    printf '%s\n' "${GH_MOCK_PR_JSON:-$default_pr}"
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$MOCK_DIR/gh"

  export GH_MOCK_CALLS="$MOCK_DIR/calls.log"
  : > "$GH_MOCK_CALLS"
}

teardown_gh_mock() {
  rm -rf "$MOCK_DIR"
}

# calls_matching <pattern> — how many recorded gh invocations match.
calls_matching() {
  grep -c -- "$1" "$GH_MOCK_CALLS" || true
}

# call_count — total recorded gh invocations.
call_count() {
  wc -l < "$GH_MOCK_CALLS" | tr -d ' '
}

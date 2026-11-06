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
#   GH_MOCK_PERMISSION_JSON body for .../collaborators/USER/permission
#   GH_MOCK_PERMISSION_FAIL non-empty → the permission call fails
#   GH_MOCK_CREATE_JSON  body for POST .../check-runs
#   GH_MOCK_CREATE_FAIL  non-empty → the create call fails
#   GH_MOCK_CREATE_FAIL_FROM  N → the Nth create call and every later one fails
#   GH_MOCK_CREATE_SEQ   non-empty → creates return ids 5001, 5002, ...
#   GH_MOCK_PATCH_FAIL   non-empty → a PATCH fails
#   GH_MOCK_CALLS        path; each invocation appends one line of args
#   GH_MOCK_TOKENS       path; each invocation appends its GH_TOKEN and args
#   GH_MOCK_CHECKRUN_JSON  body for GET .../check-runs/<id>
#   GH_MOCK_CHECKRUN_FAIL  non-empty → that lookup fails
#   GH_MOCK_LATEST_IDS     space-separated ids the commit listing reports as displayed
#   GH_MOCK_LIST_FAIL      non-empty → the commit check-runs listing request fails
#   GH_MOCK_LIST_JSON      raw body for that listing, for malformed-response cases
#   GH_MOCK_WORKFLOW       YAML served by .../contents/... (base64, like the API)
#   GH_MOCK_CONTENTS_FAIL  non-empty → the contents read fails
#   GH_MOCK_COMMENTS_JSON  body for the pull request comment listing (default [])
#   GH_MOCK_COMMENTS_FAIL  non-empty → that listing fails
#   GH_MOCK_COMMENT_CREATE_FAIL non-empty → posting a comment fails
#   GH_MOCK_COMMENT_PATCH_FAIL  non-empty → editing a comment fails
# A posted or edited comment body is kept in $MOCK_DIR/comment-<id>, and GET
# .../issues/comments/<id> serves it. $MOCK_DIR/checkrun-<id>.json, when present,
# answers GET .../check-runs/<id> ahead of GH_MOCK_CHECKRUN_JSON.

setup_gh_mock() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  PATH="$MOCK_DIR:$PATH"
  export PATH

  cat > "$MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -o pipefail

# One line per invocation, so newlines inside an argument are escaped rather
# than recorded. A check-run summary is markdown and contains them; without this
# a single call is counted as three.
[ -n "${GH_MOCK_CALLS:-}" ] && printf '%s\n' "${*//$'\n'/\\n}" >> "$GH_MOCK_CALLS"
[ -n "${GH_MOCK_TOKENS:-}" ] && printf '%s %s\n' "${GH_TOKEN:-<unset>}" "${*//$'\n'/\\n}" >> "$GH_MOCK_TOKENS"

all="$*"

# Defaults are assigned, never inlined into "${VAR:-...}": a JSON literal inside
# a parameter-expansion default loses its double quotes and keeps any single
# quotes, which produces a body jq cannot parse.
default_pr='{"head":{"sha":"abc123","ref":"feature/x","repo":{"full_name":"loft-sh/demo"}},"base":{"ref":"main"},"state":"open"}'
default_create='{"id":4242}'
default_checkrun='{"id":4242,"name":"e2e-pro: snapshots","head_sha":"abc123","app":{"id":1}}'
default_permission='{"permission":"write"}'

# field_value <name> — the value of the `-f name=value` argument.
field_value() {
  local prev=""
  for a in "$@"; do
    if [ "$prev" = "-f" ] && [ "${a%%=*}" = "$FIELD" ]; then
      printf '%s' "${a#*=}"
      return 0
    fi
    prev="$a"
  done
}

case "$all" in
  *"--method POST"*"/reactions"*)
    printf '{"id":1}\n'
    ;;
  *"--method POST"*"/issues/"*"/comments"*)
    [ -n "${GH_MOCK_COMMENT_CREATE_FAIL:-}" ] && { echo "mock: comment create failed" >&2; exit 1; }
    FIELD=body field_value "$@" > "$MOCK_DIR/comment-9001"
    printf '{"id":9001}\n'
    ;;
  *"--method PATCH"*"/issues/comments/"*)
    [ -n "${GH_MOCK_COMMENT_PATCH_FAIL:-}" ] && { echo "mock: comment patch failed" >&2; exit 1; }
    id="${all##*/issues/comments/}"; id="${id%% *}"
    FIELD=body field_value "$@" > "$MOCK_DIR/comment-${id}"
    printf '{}\n'
    ;;
  *"--method DELETE"*"/issues/comments/"*)
    id="${all##*/issues/comments/}"; id="${id%% *}"
    rm -f "$MOCK_DIR/comment-${id}"
    printf '\n'
    ;;
  *"/issues/comments/"*)
    id="${all##*/issues/comments/}"; id="${id%% *}"
    [ -f "$MOCK_DIR/comment-${id}" ] || { echo "mock: no comment ${id}" >&2; exit 1; }
    jq -n --rawfile b "$MOCK_DIR/comment-${id}" --argjson id "$id" '{id: $id, body: $b}'
    ;;
  *"/issues/"*"/comments"*)
    [ -n "${GH_MOCK_COMMENTS_FAIL:-}" ] && { echo "mock: comments listing failed" >&2; exit 1; }
    printf '%s\n' "${GH_MOCK_COMMENTS_JSON:-[]}"
    ;;
  *"/contents/"*)
    [ -n "${GH_MOCK_CONTENTS_FAIL:-}" ] && { echo "mock: contents failed" >&2; exit 1; }
    printf '{"content":"%s"}\n' "$(printf '%s' "${GH_MOCK_WORKFLOW:-}" | base64 | tr -d '\n')"
    ;;
  *"--method POST"*"check-runs"*)
    [ -n "${GH_MOCK_CREATE_FAIL:-}" ] && { echo "mock: create failed" >&2; exit 1; }
    if [ -n "${GH_MOCK_CREATE_FAIL_FROM:-}" ]; then
      creates=$(( $(cat "$MOCK_DIR/creates" 2>/dev/null || echo 0) + 1 ))
      echo "$creates" > "$MOCK_DIR/creates"
      [ "$creates" -ge "$GH_MOCK_CREATE_FAIL_FROM" ] && { echo "mock: create failed" >&2; exit 1; }
    fi
    if [ -n "${GH_MOCK_CREATE_SEQ:-}" ]; then
      seq=$(( $(cat "$MOCK_DIR/seq" 2>/dev/null || echo 5000) + 1 ))
      echo "$seq" > "$MOCK_DIR/seq"
      printf '{"id":%s}\n' "$seq"
      exit 0
    fi
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
  *"/collaborators/"*"/permission"*)
    [ -n "${GH_MOCK_PERMISSION_FAIL:-}" ] && { echo "mock: permission lookup failed" >&2; exit 1; }
    printf '%s\n' "${GH_MOCK_PERMISSION_JSON:-$default_permission}"
    ;;
  # Before the by-id case: this path also contains "check-runs".
  *"/commits/"*"check-runs"*)
    [ -n "${GH_MOCK_LIST_FAIL:-}" ] && { echo "mock: listing failed" >&2; exit 1; }
    [ -n "${GH_MOCK_LIST_JSON+x}" ] && { printf '%s\n' "$GH_MOCK_LIST_JSON"; exit 0; }
    ids=""
    for id in ${GH_MOCK_LATEST_IDS-4242}; do
      ids="${ids:+${ids},}{\"id\":${id},\"name\":\"check-${id}\",\"app\":{\"id\":1}}"
    done
    printf '{"check_runs":[%s]}\n' "$ids"
    ;;
  *"check-runs/"*)
    [ -n "${GH_MOCK_CHECKRUN_FAIL:-}" ] && { echo "mock: check-run lookup failed" >&2; exit 1; }
    id="${all##*check-runs/}"; id="${id%% *}"
    [ -f "$MOCK_DIR/checkrun-${id}.json" ] && { cat "$MOCK_DIR/checkrun-${id}.json"; exit 0; }
    printf '%s\n' "${GH_MOCK_CHECKRUN_JSON:-$default_checkrun}"
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$MOCK_DIR/gh"

  export GH_MOCK_CALLS="$MOCK_DIR/calls.log"
  : > "$GH_MOCK_CALLS"
  export GH_MOCK_TOKENS="$MOCK_DIR/tokens.log"
  : > "$GH_MOCK_TOKENS"
}

# tokens_for <pattern> — the distinct GH_TOKEN values of matching calls.
tokens_for() {
  grep -- "$1" "$GH_MOCK_TOKENS" | cut -d' ' -f1 | sort -u
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

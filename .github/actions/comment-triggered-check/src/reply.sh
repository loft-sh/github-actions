#!/usr/bin/env bash
# Reply comment I/O, sourced by start.sh, link.sh and finish.sh after lib.sh.
#
# The reply is a view of the command's check-runs. Every writer redraws it from
# the checks it lists, then reads it back and redraws again if another writer
# changed it in between, so concurrent runs converge on the real state. Nothing
# here may fail a caller: a reply that cannot be written only warns.
#
# Env: GH_TOKEN needs pull-requests: write to post and edit the reply.

REPLY_ATTEMPTS="${INPUT_REPLY_ATTEMPTS:-4}"
REPLY_JITTER_SECONDS="${INPUT_REPLY_JITTER_SECONDS:-2}"

# reply_find <repo> <pr-number> <comment-id> — id of the existing reply, empty
# when there is none. Non-zero when the comments could not be listed. Only bot
# comments count: anyone who can comment could otherwise plant the marker.
reply_find() {
  local listing
  listing="$(gh api --paginate "repos/${1}/issues/${2}/comments?per_page=100" 2>/dev/null)" || return 1
  printf '%s' "$listing" | jq -r -s --arg m "$(reply_marker "$3")" '
    [.[] | if type == "array" then .[] else . end
     | select(type == "object" and .user.type == "Bot" and ((.body // "") | startswith($m)))
     | .id] | first // ""
  ' 2>/dev/null || return 1
}

# reply_create <repo> <pr-number> <state-json> — posts a reply with no rows yet
# and prints its id.
reply_create() {
  local body created
  body="$(render_reply "$3" '[]' "${INPUT_SERVER_URL:-https://github.com}" "$1")" || return 1
  created="$(gh api --method POST "repos/${1}/issues/${2}/comments" -f "body=${body}" 2>/dev/null)" || return 1
  jq -r 'if (.id | type) == "number" then .id else empty end' <<< "$created"
}

# reply_checks <repo> <state-json> — the check-runs the state lists, as an
# array. A check that cannot be read is left out and renders as unknown.
reply_checks() {
  local id check out='[]'
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    check="$(gh api "repos/${1}/check-runs/${id}" 2>/dev/null)" || continue
    jq -e 'type == "object" and (.id | type) == "number"' <<< "$check" >/dev/null 2>&1 || continue
    out="$(jq -c --argjson c "$check" \
      '. + [$c | {id, status, conclusion, head_sha}]' <<< "$out")"
  done < <(jq -r '.runs[].id' <<< "$2")
  printf '%s' "$out"
}

# reply_refresh <repo> <reply-id> [jq-filter [jq-args...]]
# Applies the filter to the stored state, redraws from the checks, and writes
# only when the body changed. Repeats until a read finds nothing to change.
reply_refresh() {
  local repo="$1" reply_id="$2" filter="${3:-.}" attempt current body state checks
  shift 2
  [[ $# -gt 0 ]] && shift
  for ((attempt = 1; attempt <= REPLY_ATTEMPTS; attempt++)); do
    if ! current="$(gh api "repos/${repo}/issues/comments/${reply_id}" 2>/dev/null | jq -r '.body // empty')" ||
      [[ -z "$current" ]]; then
      echo "::warning::could not read reply comment ${reply_id}"
      return 0
    fi
    if ! state="$(reply_state_decode "$current")"; then
      echo "::warning::reply comment ${reply_id} has no readable state; leaving it as is"
      return 0
    fi
    if ! state="$(jq -c "$@" "$filter" <<< "$state" 2>/dev/null)"; then
      echo "::warning::could not update the state of reply comment ${reply_id}"
      return 0
    fi
    checks="$(reply_checks "$repo" "$state")"
    body="$(render_reply "$state" "$checks" "${INPUT_SERVER_URL:-https://github.com}" "$repo")" || return 0
    if [[ "$body" == "$current" ]]; then
      return 0
    fi
    if ! gh api --method PATCH "repos/${repo}/issues/comments/${reply_id}" -f "body=${body}" >/dev/null 2>&1; then
      echo "::warning::could not update reply comment ${reply_id} (attempt ${attempt}/${REPLY_ATTEMPTS})"
    fi
    # Read back after a pause, so a writer that read before this one wrote is
    # caught on the next pass.
    sleep "$(( RANDOM % (REPLY_JITTER_SECONDS + 1) ))"
  done
  echo "::warning::reply comment ${reply_id} was still changing after ${REPLY_ATTEMPTS} attempts"
}

# reply_id_of_check <repo> <check-run-id> — the reply id stored on the check as
# its external_id, empty when the check has none.
reply_id_of_check() {
  gh api "repos/${1}/check-runs/${2}" 2>/dev/null |
    jq -r '(.external_id // "") | select(test("^[0-9]+$"))' 2>/dev/null || true
}

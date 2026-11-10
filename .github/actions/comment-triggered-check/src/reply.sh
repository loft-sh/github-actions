#!/usr/bin/env bash
# Reply comment I/O, sourced by start.sh, link.sh and finish.sh after lib.sh.
#
# The reply is a view of the command's check-runs (see lib.sh). Every writer
# lists the checks, redraws the whole reply, reads it back and redraws again if
# it differs, so a writer that overwrote it with an older view is corrected by
# the next pass of any writer. Nothing here may fail a caller: a reply that
# cannot be written only warns.
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

# reply_create <repo> <pr-number> <state-json> — posts a reply that says the
# command is starting and prints its id.
reply_create() {
  local body created
  body="$(render_reply "$3" '[]' "${INPUT_SERVER_URL:-https://github.com}" "$1")" || return 1
  created="$(gh api --method POST "repos/${1}/issues/${2}/comments" -f "body=${body}" 2>/dev/null)" || return 1
  jq -r 'if (.id | type) == "number" then .id else empty end' <<< "$created"
}

# reply_checks_on <repo> <sha> — every check-run on the commit, superseded ones
# included, as one array. Non-zero when the listing failed.
reply_checks_on() {
  local listing
  listing="$(gh api --paginate "repos/${1}/commits/${2}/check-runs?filter=all&per_page=100" 2>/dev/null)" || return 1
  printf '%s' "$listing" | jq -c -s '[.[] | .check_runs? // [] | .[]]' 2>/dev/null
}

# reply_head_sha <repo> <comment-json> — the current head commit of the pull
# request the reply is on; empty when it cannot be read.
reply_head_sha() {
  local number
  number="$(jq -r '(.issue_url // "") | capture("/issues/(?<n>[0-9]+)$").n // empty' <<< "$2" 2>/dev/null)" || return 0
  [[ -n "$number" ]] || return 0
  gh api "repos/${1}/pulls/${number}" 2>/dev/null | jq -r '.head.sha // empty' 2>/dev/null || true
}

# reply_refresh <repo> <reply-id> [sha] — redraws the reply from the checks on
# its stored commit, on sha, and on the pull request's current head, writing
# only when the body changed, until a read finds nothing to change. sha is the
# caller's own commit. Every newer attempt runs on the head, so listing it lets
# even a writer from an older attempt draw the newest one.
reply_refresh() {
  local repo="$1" reply_id="$2" own_sha="${3-}" attempt comment current state body all checks sha head_sha
  for ((attempt = 1; attempt <= REPLY_ATTEMPTS; attempt++)); do
    comment="$(gh api "repos/${repo}/issues/comments/${reply_id}" 2>/dev/null)" || comment=""
    if ! current="$(jq -r '.body // empty' <<< "${comment:-null}" 2>/dev/null)" ||
      [[ -z "$current" ]]; then
      echo "::warning::could not read reply comment ${reply_id}"
      return 0
    fi
    if ! state="$(reply_state_decode "$current")"; then
      echo "::warning::reply comment ${reply_id} has no readable state; leaving it as is"
      return 0
    fi
    head_sha="$(reply_head_sha "$repo" "$comment")"
    all='[]'
    while IFS= read -r sha; do
      [[ -n "$sha" ]] || continue
      if ! checks="$(reply_checks_on "$repo" "$sha")"; then
        echo "::warning::could not list the checks on ${sha}; leaving reply comment ${reply_id} as is"
        return 0
      fi
      # Through stdin: a busy commit's checks outgrow the 128 KiB argument limit.
      if ! all="$(printf '%s\n%s\n' "$all" "$checks" | jq -c -s 'add')"; then
        echo "::warning::could not merge the checks on ${sha}; leaving reply comment ${reply_id} as is"
        return 0
      fi
    done < <(printf '%s\n%s\n%s\n' "$(jq -r '.sha // ""' <<< "$state")" "$own_sha" "$head_sha" | awk 'NF && !seen[$0]++')
    checks="$(reply_rows "$reply_id" "$all")"
    # The rows decide the commit, so a stale writer cannot pin an old one.
    state="$(jq -c --argjson rows "$checks" '.sha = ($rows[0].head_sha // .sha)' <<< "$state")"
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

# check_reply_ref <repo> <check-run-id> — {"reply": id, "sha": head, "ext": {...}}
# for a check that belongs to a reply; empty when it does not or cannot be read.
check_reply_ref() {
  gh api "repos/${1}/check-runs/${2}" 2>/dev/null | jq -c '
    ((.external_id // "") | try fromjson catch null) as $ext
    | select(($ext | type) == "object" and ($ext.r | type) == "number")
    | {reply: $ext.r, sha: (.head_sha // ""), ext: $ext}
  ' 2>/dev/null || true
}

# check_owner_token <repo> <check-run-id> — the token that may edit the check:
# GitHub lets only the identity that opened a check-run change it.
check_owner_token() {
  local owner
  if [[ -n "${INPUT_APP_TOKEN:-}" ]]; then
    owner="$(gh api "repos/${1}/check-runs/${2}" 2>/dev/null | jq -r '.app.slug // ""' 2>/dev/null)" || owner=""
    if [[ "$owner" != "github-actions" ]]; then
      printf '%s' "$INPUT_APP_TOKEN"
      return 0
    fi
  fi
  printf '%s' "${GH_TOKEN:-}"
}

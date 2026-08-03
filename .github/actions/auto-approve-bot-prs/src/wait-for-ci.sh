#!/usr/bin/env bash
# Polls non-self check-runs AND commit statuses on the PR head until they
# complete. Outputs ci_green=true only if every non-self signal ends
# success/skipped/neutral AND the API answered cleanly on the deciding poll.
#
# Commit statuses matter because external systems (Netlify, etc.) post results
# via the legacy statuses API, not check-runs. Without this, the script sees
# "nothing pending" and approves while external CI is still reporting failures.
#
# A minimum number of attempts is also required before declaring green: an
# external check that has not yet registered a "pending" signal looks
# indistinguishable from "no check configured". Waiting one settle period
# lets slow registrants (observed: 2+ minutes in the wild) appear before
# approval.
#
# API errors never degrade to silent green. Every gh/jq error is captured and
# treated as "unknown state" — the poll does not count toward the settle
# floor, and consecutive errors eventually time out to ci_green=false.
# Default-deny: if we cannot prove CI is clean, we do not approve.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_HEAD_SHA, SELF_RUN_ID
# Optional env:
#   WAIT_MAX_ATTEMPTS  (default 90)  – hard ceiling on polls
#   WAIT_MIN_ATTEMPTS  (default 12)  – floor before ci_green=true is allowed
#   WAIT_SLEEP_SECONDS (default 10)  – seconds between polls
# Writes: ci_green=true|false to $GITHUB_OUTPUT (and stdout).
# Always exits 0.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_HEAD_SHA:?PR_HEAD_SHA required}"
: "${SELF_RUN_ID:?SELF_RUN_ID required}"

max_attempts="${WAIT_MAX_ATTEMPTS:-90}"
min_attempts="${WAIT_MIN_ATTEMPTS:-12}"
sleep_seconds="${WAIT_SLEEP_SECONDS:-10}"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

# Scratch file holding the stderr of the most recent gh call. This has to be a
# file, not a variable: gh_json is always invoked inside a command substitution,
# so it runs in a subshell and any variable it sets is lost to the caller. (The
# EXIT trap below is likewise not inherited by that subshell, so it fires only
# once, on the real exit — the file is not deleted out from under the caller.)
#
# A failure to allocate the file must NOT be fatal. This script documents
# "Always exits 0" and action.yml promises the job never hard-fails, and a direct
# consumer of the composite has no continue-on-error to hide behind. So degrade:
# an empty GH_ERR_FILE means "capture unavailable", not "abort".
GH_ERR_FILE=""
if ! GH_ERR_FILE="$(mktemp 2>/dev/null)"; then
  GH_ERR_FILE=""
  echo "::warning::could not allocate a temp file for API error capture; errors will be reported without detail"
fi
trap '[ -n "$GH_ERR_FILE" ] && rm -f "$GH_ERR_FILE"' EXIT

# gh_json <api-path> — fetch json body; on any failure print empty and return 1.
# Crucially does NOT swallow errors into "[]" — callers must distinguish
# "API said there is nothing" from "API failed and we have no idea".
gh_json() {
  local path="$1" body err="${GH_ERR_FILE:-/dev/null}"
  [ -n "$GH_ERR_FILE" ] && : > "$GH_ERR_FILE"
  if ! body=$(gh api "$path" --paginate 2>"$err"); then
    return 1
  fi
  # Clear on success so a later unrelated failure cannot report stale text.
  [ -n "$GH_ERR_FILE" ] && : > "$GH_ERR_FILE"
  printf '%s' "$body"
}

# gh_last_error — one-line summary of why the last gh call failed, for logs.
# Discarding this is how a permanent permission problem masquerades as a
# transient blip: both produce the identical "API failed" line and the identical
# default-deny exit, so a misconfigured token is indistinguishable from a bad
# minute at GitHub. The single most useful case is a 403 on a private repo,
# which means the CI-read token cannot reach the Checks API.
#
# This text is attacker-adjacent: it is API-controlled and goes straight into a
# ::warning::/::error:: line, so it is sanitized rather than trusted.
#   - CR and LF both terminate a log line for the runner, so a raw one in the
#     error text would start a NEW line, and a line beginning `::` is a workflow
#     command. Collapse both to spaces.
#   - Non-ASCII is dropped rather than byte-truncated, so the length cap cannot
#     split a UTF-8 sequence mid-character.
#   - `%` is the workflow-command escape introducer, so a literal `%0A`/`%25` in
#     the source would otherwise be decoded into the annotation. Escape it last,
#     after the cut, so the cap cannot bisect an escape we just wrote.
# Never fails: a subshell abort here would kill the script under `set -e` before
# it could emit ci_green, which is the same contract violation as a fatal mktemp.
gh_last_error() {
  [ -n "$GH_ERR_FILE" ] || return 0
  [ -s "$GH_ERR_FILE" ] || return 0
  { LC_ALL=C tr '\n\r\t' '   ' < "$GH_ERR_FILE" \
      | LC_ALL=C tr -cd '\040-\176' \
      | cut -c1-300 \
      | sed 's/%/%25/g'; } 2>/dev/null || true
}

# jq_or_fail [jq-flags...] <jq-expr> <json>  — run jq on $json with optional
# flags (e.g. -r). Returns non-zero on parse failure. Callers must check
# exit status; silent empty output here is not the same as success.
jq_or_fail() {
  local json="${!#}"
  local args=( "${@:1:$#-1}" )
  jq "${args[@]}" <<<"$json" 2>/dev/null || return 1
}

# Self-identification: exclude check-runs whose details_url contains our run id,
# `.../runs/<SELF_RUN_ID>/...`. Works for both check-runs and statuses from
# github-actions.
EXCLUDE_PATTERN="/runs/${SELF_RUN_ID}/"

consecutive_errors=0
max_consecutive_errors=5
# Declared up front: a jq parse failure sets poll_errored without going through
# gh_last_error, and `set -u` would abort on an unset read in the bail path.
last_error=""

for attempt in $(seq 1 "$max_attempts"); do
  poll_errored=0
  # Reset per poll. Without this, an API error early in the run stays in
  # last_error and gets reported by a LATER jq-parse failure, sending the
  # operator to check token permissions for a malformed-response fault. That is
  # the same misdiagnosis this error reporting exists to prevent.
  last_error=""

  # -- Fetch check-runs -----------------------------------------------------
  runs_raw=""
  if ! runs_raw=$(gh_json "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/check-runs"); then
    last_error="$(gh_last_error)"
    echo "::warning::attempt ${attempt}/${max_attempts}: check-runs API failed${last_error:+ (${last_error})}"
    poll_errored=1
  fi

  # Dedupe by name: GitHub keeps historical attempts (including cancelled ones
  # superseded by reruns) in the check-runs list, and the current state is the
  # one with the latest started_at. Treating every past attempt as live is what
  # makes a superseded `cancelled` from an older run silently block approval
  # even though the same check's latest attempt is green.
  #
  # `.id` is the tiebreaker when two attempts share an identical started_at —
  # a common case when concurrency-group cancellation and the winning run
  # start within the same second. GitHub allocates check-run IDs
  # monotonically, so the larger id is always the newer attempt.
  other=""
  if [ "$poll_errored" -eq 0 ]; then
    if ! other=$(jq_or_fail '
      (.check_runs // [])
      | [.[] | select((.details_url // "") | contains("'"$EXCLUDE_PATTERN"'") | not)]
      | group_by(.name // "")
      | map(sort_by(.started_at // "", .id // 0) | last)
    ' "$runs_raw"); then
      last_error="malformed check-runs response (jq could not parse it)"
      echo "::warning::attempt ${attempt}/${max_attempts}: check-runs jq parse failed"
      poll_errored=1
    fi
  fi

  # `cancelled` is special: GitHub's concurrency-group cancellation marks the
  # superseded run cancelled and immediately queues a replacement. There's a
  # short window (observed: 5–10s) where the cancelled attempt is registered
  # but the replacement is not yet visible. In that window the dedup-by-latest
  # logic above has nothing to pick — only the cancelled attempt exists — so
  # treating cancelled as a hard failure here would defeat the dedup fix and
  # bail before the rerun lands. Split it out: terminal failures bail
  # immediately; cancelled-only is held until the settle floor so the
  # replacement has a chance to register and dedup can pick it.
  cr_pending=0 cr_real_failed=0 cr_real_failed_detail=""
  cr_cancelled=0 cr_cancelled_detail="" cr_pending_names=""
  if [ "$poll_errored" -eq 0 ]; then
    cr_pending=$(           jq_or_fail '[.[] | select(.status != "completed")] | length'                                                                                                          "$other" ) || poll_errored=1
    cr_real_failed=$(       jq_or_fail '[.[] | select(.conclusion != null and ([.conclusion] | inside(["success","skipped","neutral","cancelled"]) | not))] | length'                             "$other" ) || poll_errored=1
    cr_real_failed_detail=$(jq_or_fail -r '[.[] | select(.conclusion != null and ([.conclusion] | inside(["success","skipped","neutral","cancelled"]) | not)) | "\(.name // "unnamed")=\(.conclusion)"] | join(", ")' "$other" ) || poll_errored=1
    cr_cancelled=$(         jq_or_fail '[.[] | select(.conclusion == "cancelled")] | length'                                                                                                      "$other" ) || poll_errored=1
    cr_cancelled_detail=$(  jq_or_fail -r '[.[] | select(.conclusion == "cancelled") | .name // "unnamed"] | join(", ")'                                                                          "$other" ) || poll_errored=1
    cr_pending_names=$(     jq_or_fail -r '[.[] | select(.status != "completed") | .name // "unnamed"] | join(", ")'                                                                              "$other" ) || poll_errored=1
  fi

  # -- Fetch commit statuses ------------------------------------------------
  statuses_raw=""
  if [ "$poll_errored" -eq 0 ]; then
    if ! statuses_raw=$(gh_json "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/status"); then
      last_error="$(gh_last_error)"
      echo "::warning::attempt ${attempt}/${max_attempts}: statuses API failed${last_error:+ (${last_error})}"
      poll_errored=1
    fi
  fi

  statuses_other=""
  if [ "$poll_errored" -eq 0 ]; then
    if ! statuses_other=$(jq_or_fail '
      (.statuses // [])
      | [.[] | select((.target_url // "") | contains("'"$EXCLUDE_PATTERN"'") | not)]
    ' "$statuses_raw"); then
      last_error="malformed commit-status response (jq could not parse it)"
      echo "::warning::attempt ${attempt}/${max_attempts}: statuses jq parse failed"
      poll_errored=1
    fi
  fi

  st_pending=0 st_failed=0 st_failed_detail="" st_pending_names=""
  if [ "$poll_errored" -eq 0 ]; then
    st_pending=$(       jq_or_fail '[.[] | select(.state == "pending")] | length'                                                    "$statuses_other" ) || poll_errored=1
    st_failed=$(        jq_or_fail '[.[] | select(.state == "failure" or .state == "error")] | length'                               "$statuses_other" ) || poll_errored=1
    st_failed_detail=$( jq_or_fail -r '[.[] | select(.state == "failure" or .state == "error") | "\(.context // "unnamed")=\(.state)"] | join(", ")' "$statuses_other" ) || poll_errored=1
    st_pending_names=$( jq_or_fail -r '[.[] | select(.state == "pending") | .context // "unnamed"] | join(", ")'                     "$statuses_other" ) || poll_errored=1
  fi

  # -- Consume the poll -----------------------------------------------------
  if [ "$poll_errored" -eq 1 ]; then
    # The jq_or_fail metric extractions above set poll_errored without a message
    # of their own; give them one rather than reporting "unknown".
    [ -n "$last_error" ] || last_error="could not extract check state from the API response"
    # Default-deny on API/parse errors: this poll does not count toward the
    # settle floor, and too many consecutive errors exit non-green.
    consecutive_errors=$(( consecutive_errors + 1 ))
    if [ "$consecutive_errors" -ge "$max_consecutive_errors" ]; then
      # ::error:: rather than ::notice::. The job keeps its continue-on-error
      # safety net, so this still cannot turn a caller's CI red, but the run no
      # longer looks clean. Refusing to approve is a real outcome and something
      # downstream may be blocking on the merge that will now never happen.
      echo "::error::Too many consecutive API errors (${consecutive_errors}); refusing to approve. Last error: ${last_error:-unknown}"
      echo "::error::If that is a 403 or 404 on a private repository, the CI-read token cannot reach the Checks API. Fine-grained PATs have no Checks permission at all. Leave ci-read-token unset so it falls back to GITHUB_TOKEN, and grant 'checks: read' and 'statuses: read' in the CALLER workflow: a reusable workflow can only downgrade the caller's permissions, never add to them."
      emit ci_green false
      exit 0
    fi
    sleep "$sleep_seconds"
    continue
  fi
  consecutive_errors=0

  pending=$(( cr_pending + st_pending ))
  real_failed=$(( cr_real_failed + st_failed ))
  echo "attempt ${attempt}/${max_attempts}: check_runs(pending=${cr_pending} failed=${cr_real_failed} cancelled=${cr_cancelled}) statuses(pending=${st_pending} failed=${st_failed})"

  # Terminal failures (failure, timed_out, action_required, etc.) bail
  # immediately — these are not transient and won't be replaced.
  if [ "$real_failed" -gt 0 ]; then
    details=$(printf '%s\n%s' "$cr_real_failed_detail" "$st_failed_detail" | awk 'NF' | paste -sd, - | sed 's/,/, /g')
    echo "::notice::Other CI checks failed; skipping approval. Failing: ${details:-unknown}"
    emit ci_green false
    exit 0
  fi

  # Cancelled checks may be in the middle of a concurrency-triggered rerun.
  # Past the settle floor we stop waiting and treat them as final — the
  # replacement should have registered by now if it was ever going to.
  if [ "$cr_cancelled" -gt 0 ] && [ "$attempt" -ge "$min_attempts" ]; then
    echo "::notice::Cancelled checks did not get replaced within settle period; skipping approval. Cancelled: ${cr_cancelled_detail:-unknown}"
    emit ci_green false
    exit 0
  fi

  # Surface which signals we are still waiting on. Helps operators diagnose
  # "why is this job still running?" without enabling step debug logging.
  if [ "$pending" -gt 0 ]; then
    waiting=$(printf '%s\n%s' "$cr_pending_names" "$st_pending_names" | awk 'NF' | paste -sd, - | sed 's/,/, /g')
    echo "  pending: ${waiting:-<unnamed>}"
  fi
  if [ "$cr_cancelled" -gt 0 ]; then
    echo "  cancelled (waiting for concurrency replacement): ${cr_cancelled_detail}"
  fi

  # Hold the "green" verdict until the settle floor. A first-poll "pending=0"
  # can simply mean external checks have not registered yet (e.g. Netlify
  # webhook still in flight). Waiting min_attempts polls before the first
  # green verdict gives slow registrants a chance to show up. Cancelled
  # checks also keep us out of green — handled above by the post-settle bail.
  if [ "$pending" -eq 0 ] && [ "$cr_cancelled" -eq 0 ] && [ "$attempt" -ge "$min_attempts" ]; then
    emit ci_green true
    exit 0
  fi
  sleep "$sleep_seconds"
done

# ::error:: for the same reason as the consecutive-error bail: refusing to
# approve is a real outcome, a release cut may be blocking on the merge, and this
# is the path taken by errors that never hit max_consecutive_errors in a row (and
# the only reachable one when a caller sets wait-max-attempts below it).
echo "::error::Timed out waiting for other CI checks after ${max_attempts} attempts; refusing to approve. Last error: ${last_error:-none (checks were still pending)}"
emit ci_green false

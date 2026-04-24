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

# gh_json <api-path> — fetch json body; on any failure print empty and return 1.
# Crucially does NOT swallow errors into "[]" — callers must distinguish
# "API said there is nothing" from "API failed and we have no idea".
gh_json() {
  local path="$1" body
  if ! body=$(gh api "$path" --paginate 2>/dev/null); then
    return 1
  fi
  printf '%s' "$body"
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

for attempt in $(seq 1 "$max_attempts"); do
  poll_errored=0

  # -- Fetch check-runs -----------------------------------------------------
  runs_raw=""
  if ! runs_raw=$(gh_json "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/check-runs"); then
    echo "::warning::attempt ${attempt}/${max_attempts}: check-runs API failed"
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
      echo "::warning::attempt ${attempt}/${max_attempts}: check-runs jq parse failed"
      poll_errored=1
    fi
  fi

  cr_pending=0 cr_failed=0 cr_failed_detail="" cr_pending_names=""
  if [ "$poll_errored" -eq 0 ]; then
    cr_pending=$(       jq_or_fail '[.[] | select(.status != "completed")] | length'                                                                                                  "$other" ) || poll_errored=1
    cr_failed=$(        jq_or_fail '[.[] | select(.conclusion != null and ([.conclusion] | inside(["success","skipped","neutral"]) | not))] | length'                                 "$other" ) || poll_errored=1
    cr_failed_detail=$( jq_or_fail -r '[.[] | select(.conclusion != null and ([.conclusion] | inside(["success","skipped","neutral"]) | not)) | "\(.name // "unnamed")=\(.conclusion)"] | join(", ")' "$other" ) || poll_errored=1
    cr_pending_names=$( jq_or_fail -r '[.[] | select(.status != "completed") | .name // "unnamed"] | join(", ")'                                                                      "$other" ) || poll_errored=1
  fi

  # -- Fetch commit statuses ------------------------------------------------
  statuses_raw=""
  if [ "$poll_errored" -eq 0 ]; then
    if ! statuses_raw=$(gh_json "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/status"); then
      echo "::warning::attempt ${attempt}/${max_attempts}: statuses API failed"
      poll_errored=1
    fi
  fi

  statuses_other=""
  if [ "$poll_errored" -eq 0 ]; then
    if ! statuses_other=$(jq_or_fail '
      (.statuses // [])
      | [.[] | select((.target_url // "") | contains("'"$EXCLUDE_PATTERN"'") | not)]
    ' "$statuses_raw"); then
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
    # Default-deny on API/parse errors: this poll does not count toward the
    # settle floor, and too many consecutive errors exit non-green.
    consecutive_errors=$(( consecutive_errors + 1 ))
    if [ "$consecutive_errors" -ge "$max_consecutive_errors" ]; then
      echo "::notice::Too many consecutive API errors (${consecutive_errors}); refusing to approve"
      emit ci_green false
      exit 0
    fi
    sleep "$sleep_seconds"
    continue
  fi
  consecutive_errors=0

  pending=$(( cr_pending + st_pending ))
  failed=$(( cr_failed + st_failed ))
  echo "attempt ${attempt}/${max_attempts}: check_runs(pending=${cr_pending} failed=${cr_failed}) statuses(pending=${st_pending} failed=${st_failed})"

  if [ "$failed" -gt 0 ]; then
    details=$(printf '%s\n%s' "$cr_failed_detail" "$st_failed_detail" | awk 'NF' | paste -sd, - | sed 's/,/, /g')
    echo "::notice::Other CI checks failed; skipping approval. Failing: ${details:-unknown}"
    emit ci_green false
    exit 0
  fi

  # Surface which signals we are still waiting on. Helps operators diagnose
  # "why is this job still running?" without enabling step debug logging.
  if [ "$pending" -gt 0 ]; then
    waiting=$(printf '%s\n%s' "$cr_pending_names" "$st_pending_names" | awk 'NF' | paste -sd, - | sed 's/,/, /g')
    echo "  pending: ${waiting:-<unnamed>}"
  fi

  # Hold the "green" verdict until the settle floor. A first-poll "pending=0"
  # can simply mean external checks have not registered yet (e.g. Netlify
  # webhook still in flight). Waiting min_attempts polls before the first
  # green verdict gives slow registrants a chance to show up.
  if [ "$pending" -eq 0 ] && [ "$attempt" -ge "$min_attempts" ]; then
    emit ci_green true
    exit 0
  fi
  sleep "$sleep_seconds"
done

echo "::notice::Timed out waiting for other CI checks"
emit ci_green false

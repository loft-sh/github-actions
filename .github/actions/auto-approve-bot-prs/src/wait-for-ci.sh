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
# `cancelled` is not treated as final while a newer check suite on the same head
# SHA is still running: that is a concurrency rerun on its way to replacing it.
# The floor does not bound this case — a cancelled job queued behind a long
# build cannot be replaced until that build finishes, minutes after the floor
# expires. max_attempts is the bound.
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

# sanitize_for_log / safe. Sourced before the input coercion below, because a
# rejected wait value is itself interpolated into a log line. A missing lib is a
# packaging fault, not a runtime one, so it exits non-zero like missing env does
# rather than degrading to unsanitized output.
# shellcheck source=.github/actions/auto-approve-bot-prs/src/lib/log.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh"

# gh_last_error — one-line summary of why the last gh call failed, for logs.
# Discarding this is how a permanent permission problem masquerades as a
# transient blip: both produce the identical "API failed" line and the identical
# default-deny exit, so a misconfigured token is indistinguishable from a bad
# minute at GitHub. The single most useful case is a 403, which means the
# CI-read token cannot reach the Checks API.
gh_last_error() {
  [ -n "$GH_ERR_FILE" ] || return 0
  [ -s "$GH_ERR_FILE" ] || return 0
  sanitize_for_log < "$GH_ERR_FILE"
}

# Coerce rather than trust. A non-numeric value here used to reach `sleep` and
# `seq` directly and abort the script under `set -e` with no ci_green emitted at
# all — exit 1, which for a direct consumer of the composite (no
# continue-on-error in the documented usage) is a red job. The contract is that
# no input can do that.
# An upper bound matters as much as the lower one. Without it the accept/reject
# line was an accident of int64 overflow in `[ -gt ]`, so a plausible fat-finger
# like 1000000000 was accepted and the loop below then hung with no output at all
# until GitHub's 6-hour job timeout — a strictly worse version of the stall this
# script exists to prevent. The length test comes first so overflow never decides.
numeric_or_default() {
  local name="$1" value="$2" fallback="$3" max="$4"
  if [ -n "$value" ] && [ -z "${value//[0-9]/}" ] && [ "${#value}" -le 9 ] \
     && [ "$value" -gt 0 ] && [ "$value" -le "$max" ]; then
    printf '%s' "$value"
    return 0
  fi
  echo "::warning::${name}='$(safe "$value")' is not an integer in 1..${max}; using ${fallback}" >&2
  printf '%s' "$fallback"
}
max_attempts="$(numeric_or_default WAIT_MAX_ATTEMPTS "${WAIT_MAX_ATTEMPTS:-90}" 90 100000)"
min_attempts="$(numeric_or_default WAIT_MIN_ATTEMPTS "${WAIT_MIN_ATTEMPTS:-12}" 12 100000)"
sleep_seconds="$(numeric_or_default WAIT_SLEEP_SECONDS "${WAIT_SLEEP_SECONDS:-10}" 10 3600)"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

# Scratch file holding the stderr of the most recent gh call. This has to be a
# file, not a variable: gh_json is always invoked inside a command substitution,
# so it runs in a subshell and any variable it sets is lost to the caller. (The
# EXIT trap below IS inherited by that subshell but never executes on its exit,
# so it fires exactly once, on the real exit — verified: the file is not deleted
# out from under the caller, and the guarded trap does not alter exit status.)
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
# last_error is reset every poll (see below), which is right for attributing a
# poll's own failure but loses the actionable one: four real 403s followed by one
# malformed response would report only the parse error. Keep the first as well.
first_error=""

attempt=0
while [ "$attempt" -lt "$max_attempts" ]; do
  attempt=$(( attempt + 1 ))
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
  #
  # "Latest wins" alone lets a `skipped` bury a real failure. A workflow that
  # skips its expensive job on a no-op PR-description edit (vcluster-pro's e2e
  # gates on DEVOPS-1057 do exactly this) publishes a check-run named the same as
  # the job that already FAILED on this SHA, with a later started_at. Dedup then
  # picks `skipped`, which counts as green below, and a PR whose suite genuinely
  # failed becomes approvable. Note the Checks API is not the problem here and
  # `filter=latest` would not help: it dedupes within a check suite, and each run
  # gets its own suite, so the API faithfully returns every attempt. The
  # collapsing is ours, so the fix is ours.
  #
  # Rank by information content, then recency. `skipped` and `cancelled` carry no
  # verdict about the code; success/neutral and the failure classes do. So prefer
  # the latest attempt that actually reached a verdict, and fall back to the
  # latest attempt overall when none did. A still-running attempt outranks
  # everything, because a rerun in flight means the verdict is not in yet.
  #
  # This ordering is what keeps each case right:
  #   cancelled then skipped   -> skipped   (concurrency replacement; unblocks)
  #   cancelled then success   -> success   (ditto)
  #   failure   then skipped   -> failure   (the bug above; stays blocked)
  #   failure   then success   -> success   (a real re-run of a flake; unblocks)
  #   success   then pending   -> pending   (wait for the rerun)
  other=""
  if [ "$poll_errored" -eq 0 ]; then
    if ! other=$(jq_or_fail '
      def rank:
        if (.status // "") != "completed" then 3
        elif ([.conclusion // ""] | inside(["skipped","cancelled"])) then 1
        else 2
        end;
      (.check_runs // [])
      | [.[] | select((.details_url // "") | contains("'"$EXCLUDE_PATTERN"'") | not)]
      | group_by(.name // "")
      | map(sort_by(rank, .started_at // "", .id // 0) | last)
    ' "$runs_raw"); then
      last_error="malformed check-runs response (jq could not parse it)"
      echo "::warning::attempt ${attempt}/${max_attempts}: check-runs jq parse failed"
      poll_errored=1
    fi
  fi

  # `cancelled` is special: GitHub's concurrency-group cancellation marks the
  # superseded run cancelled and immediately queues a replacement. There's a
  # window where the cancelled attempt is registered but the replacement is not
  # yet visible. In that window the dedup-by-latest logic above has nothing to
  # pick — only the cancelled attempt exists — so treating cancelled as a hard
  # failure here would defeat the dedup fix and bail before the rerun lands.
  # Split it out: terminal failures bail immediately; cancelled is held while a
  # replacement is still plausibly on its way (see the watermark below).
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

  # How long a cancelled check may be held used to be exactly the settle floor
  # (~120s at the defaults). That assumed a replacement registers in seconds,
  # which is only true when the cancelled job starts immediately. When it sits
  # behind an earlier job in the same workflow — an image build, say — the
  # replacement's check-run does not exist until that build finishes, minutes
  # later. The floor then expires first and the bail throws away a rerun that
  # was still coming. Observed on vcluster-pro#2155: two e2e runs cancelled by
  # concurrency at 12:47, replacement check-runs registered 12:51:41, bail at
  # 12:49:45 — and the release cut it was gating stalled behind it.
  #
  # So do not time the tolerance. Condition it on an observable: is a NEWER
  # check suite than the cancelled one still running? GitHub allocates check
  # suite ids monotonically and a re-triggered workflow lands in a new suite,
  # so a non-completed check-run in a higher-numbered suite is exactly the
  # "a rerun is in flight" signal, and its absence is "nothing more is coming".
  #
  # Read from the check-runs payload we already have, not from /actions/runs.
  # Resolving each cancelled suite to its workflow and looking for a newer run
  # of that same workflow would be more precise, but that endpoint needs
  # `actions: read` — a grant every caller would have to add, degrading to this
  # same bail until they all did. DEVOPS-1254 was exactly that class of bug.
  #
  # The wait stays bounded three ways: `other` excludes our own run, so this job
  # cannot justify waiting on itself; a genuine user-cancelled check has no
  # newer suite behind it and still bails at the floor; and anything left in
  # flight is capped by max_attempts.
  #
  # The watermark is derived inside jq rather than round-tripped through the
  # shell so the comparison stays numeric — suite ids are ~11 digits and a
  # string compare would order them by prefix. `// 0` on both sides makes a
  # missing check_suite read as oldest, never as newer.
  cr_newer_suite_pending=0
  if [ "$poll_errored" -eq 0 ] && [ "$cr_cancelled" -gt 0 ]; then
    # shellcheck disable=SC2016  # $w is a jq variable, not a shell one
    cr_newer_suite_pending=$(jq_or_fail '
      ([.[] | select(.conclusion == "cancelled") | .check_suite.id // 0] | max // 0) as $w
      | [.[] | select(.status != "completed") | select((.check_suite.id // 0) > $w)]
      | length
    ' "$other" ) || poll_errored=1
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
    [ -n "$first_error" ] || first_error="$last_error"
    # Default-deny on API/parse errors: this poll does not count toward the
    # settle floor, and too many consecutive errors exit non-green.
    consecutive_errors=$(( consecutive_errors + 1 ))
    if [ "$consecutive_errors" -ge "$max_consecutive_errors" ]; then
      # Only worth printing when it differs, else the same blob appears twice.
      first_error_clause=""
      [ -n "$first_error" ] && [ "$first_error" != "$last_error" ] \
        && first_error_clause="; first error: ${first_error}"
      # ::error:: rather than ::notice::. The job keeps its continue-on-error
      # safety net, so this still cannot turn a caller's CI red, but the run no
      # longer looks clean. Refusing to approve is a real outcome and something
      # downstream may be blocking on the merge that will now never happen.
      echo "::error::Too many consecutive API errors (${consecutive_errors}); refusing to approve. Last error: ${last_error:-unknown}${first_error_clause}"
      echo "::error::If that is a 403 or 404 on a private repository, the CI-read token cannot reach the Checks API. Fine-grained PATs have no Checks permission at all. Leave ci-read-token unset so it falls back to GITHUB_TOKEN, and grant 'checks: read' and 'statuses: read' in the CALLER workflow: a reusable workflow can only downgrade the caller's permissions, never add to them."
      emit ci_green false
      exit 0
    fi
    sleep "$sleep_seconds"
    continue
  fi
  # Reset first_error with the streak. Keeping it across a recovered poll is the
  # F1 misattribution bug one variable over: a 403 that has since resolved would
  # be reported as the "first error" for a later, unrelated parse-failure streak.
  consecutive_errors=0
  first_error=""

  pending=$(( cr_pending + st_pending ))
  real_failed=$(( cr_real_failed + st_failed ))
  echo "attempt ${attempt}/${max_attempts}: check_runs(pending=${cr_pending} failed=${cr_real_failed} cancelled=${cr_cancelled}) statuses(pending=${st_pending} failed=${st_failed})"

  # Terminal failures (failure, timed_out, action_required, etc.) bail
  # immediately — these are not transient and won't be replaced.
  if [ "$real_failed" -gt 0 ]; then
    # Sanitized: these carry attacker-settable check names / status contexts.
    details=$(printf '%s\n%s' "$cr_real_failed_detail" "$st_failed_detail" | awk 'NF' | paste -sd, - | sed 's/,/, /g' | sanitize_for_log 1000)
    echo "::notice::Other CI checks failed; skipping approval. Failing: ${details:-unknown}"
    emit ci_green false
    exit 0
  fi

  # Cancelled checks may be in the middle of a concurrency-triggered rerun.
  # Past the settle floor we stop waiting and treat them as final — unless a
  # newer check suite is still running, which means the rerun that will replace
  # them has started but not yet reached the cancelled job. Waiting on that is
  # bounded by max_attempts.
  if [ "$cr_cancelled" -gt 0 ] && [ "$attempt" -ge "$min_attempts" ] \
     && [ "$cr_newer_suite_pending" -eq 0 ]; then
    # ::error:: because a cancelled check is not red anywhere else: unlike the
    # failed-checks path below, this annotation is the only signal an operator
    # gets, and a release cut may be blocking on the merge.
    echo "::error::Cancelled checks are final (no newer check suite is still running); skipping approval. Cancelled: $(safe "${cr_cancelled_detail:-unknown}")"
    emit ci_green false
    exit 0
  fi

  # Surface which signals we are still waiting on. Helps operators diagnose
  # "why is this job still running?" without enabling step debug logging.
  if [ "$pending" -gt 0 ]; then
    waiting=$(printf '%s\n%s' "$cr_pending_names" "$st_pending_names" | awk 'NF' | paste -sd, - | sed 's/,/, /g' | sanitize_for_log 1000)
    echo "  pending: ${waiting:-<unnamed>}"
  fi
  # Distinguish the two holds, because they end differently: one is waiting on a
  # rerun that is demonstrably running (ends when it registers, or at
  # max_attempts), the other is inside the settle floor on nothing but hope
  # (ends at min_attempts). Reading "waiting for replacement" on a poll where
  # nothing was coming is what made the vcluster-pro#2155 timeline hard to read.
  if [ "$cr_cancelled" -gt 0 ]; then
    if [ "$cr_newer_suite_pending" -gt 0 ]; then
      echo "  cancelled (superseded; newer check suite still running): $(safe "$cr_cancelled_detail")"
    else
      echo "  cancelled (waiting for concurrency replacement): $(safe "$cr_cancelled_detail")"
    fi
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

first_error_clause=""
[ -n "$first_error" ] && [ "$first_error" != "$last_error" ] \
  && first_error_clause="; first error: ${first_error}"
# ::error:: for the same reason as the consecutive-error bail: refusing to
# approve is a real outcome, a release cut may be blocking on the merge, and this
# is the path taken by errors that never hit max_consecutive_errors in a row (and
# the only reachable one when a caller sets wait-max-attempts below it).
echo "::error::Timed out waiting for other CI checks after ${max_attempts} attempts; refusing to approve. Last error: ${last_error:-none (checks were still pending)}${first_error_clause}"
emit ci_green false

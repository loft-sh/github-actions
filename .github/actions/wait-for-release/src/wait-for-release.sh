#!/usr/bin/env bash
# Waits for a GitHub Release to appear in another repository.
#
# Cross-repo release pipelines carry an ordering dependency: one repo's build
# uploads assets into a release that another repo's build creates. Waiting on
# the release alone cannot distinguish "the producer is still building" from
# "the producer already failed and nothing will ever appear", so the wait is
# optionally status-aware. When INPUT_WORKFLOW names the workflow that produces
# the release, a run that has already concluded unsuccessfully fails this wait
# immediately, printing that run's URL and the recovery order, instead of
# spending the whole timeout on a precondition that can never be met.
#
# Three lookup outcomes stay strictly distinct - present, cleanly absent, and
# API error - because collapsing them is how a waiter goes wrong: an API error
# read as "absent" waits out the timeout on a release that is actually there,
# and read as "present" it lets the caller upload into a release that does not
# exist. API errors also never end the wait on their own; up to
# WAIT_MAX_API_FAILURES consecutive failures are tolerated so one flaky call
# cannot fail an otherwise healthy release.
#
# Required env: GH_TOKEN, INPUT_REPO, INPUT_VERSION
# Optional env:
#   INPUT_WORKFLOW         (default empty) - producer workflow, enables fail-fast
#   WAIT_MAX_ATTEMPTS      (default 120)   - polls before giving up
#   WAIT_INTERVAL_SECONDS  (default 15)    - seconds between polls
#   WAIT_MAX_API_FAILURES  (default 5)     - consecutive API failures tolerated
# Writes: waited-seconds, release-url to $GITHUB_OUTPUT (and stdout).
# Exits 0 once the release exists, 1 otherwise.
set -euo pipefail

: "${INPUT_REPO:?INPUT_REPO is required}"
: "${INPUT_VERSION:?INPUT_VERSION is required}"

WORKFLOW="${INPUT_WORKFLOW:-}"
MAX_ATTEMPTS="${WAIT_MAX_ATTEMPTS:-120}"
INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-15}"
MAX_API_FAILURES="${WAIT_MAX_API_FAILURES:-5}"

# A producer run that reaches any of these will never go on to create the
# release, so observing one is grounds to stop waiting immediately.
TERMINAL_CONCLUSIONS="failure cancelled timed_out startup_failure"

# Polls to tolerate where the producer reports success but the release is still
# missing, before calling it an inconsistency. One poll of grace absorbs the lag
# between a run finishing and its release becoming readable.
SUCCESS_ABSENT_GRACE=2

emit() {
  local key="$1" value="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  printf '%s=%s\n' "$key" "$value"
}

# release_present <repo> <version>
#   0 = release exists, 1 = cleanly absent (404), 2 = API error.
release_present() {
  local repo="$1" version="$2" err
  if err=$(gh api "repos/${repo}/releases/tags/${version}" 2>&1 >/dev/null); then
    return 0
  fi
  if printf '%s' "$err" | grep -qiE 'not found|HTTP 404'; then
    return 1
  fi
  printf '%s\n' "$err" >&2
  return 2
}

# producer_state <repo> <workflow> <version>
#   Prints "<status>|<conclusion>|<url>" for the producer run of <version>.
#   0 = printed, 1 = no run yet, 2 = API error.
#
# `workflow_dispatch` against a tag ref records head_branch as the tag, so
# --branch <version> selects the run for that version. A re-run keeps the same
# run id, so status/conclusion always describe the latest attempt.
producer_state() {
  local repo="$1" workflow="$2" version="$3" json
  if ! json=$(gh run list --repo "$repo" --workflow "$workflow" --branch "$version" \
    --limit 1 --json status,conclusion,url 2>/dev/null); then
    return 2
  fi
  if [ -z "$json" ] || [ "$json" = "[]" ]; then
    return 1
  fi
  jq -r '.[0] | "\(.status)|\(.conclusion)|\(.url)"' <<<"$json" 2>/dev/null || return 2
}

# is_terminal <conclusion> - true when a producer conclusion rules out a release.
is_terminal() {
  case " ${TERMINAL_CONCLUSIONS} " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

# check_producer <attempt> - inspect the producer run and decide whether to stop
# waiting. Returns 0 to keep waiting, 1 to fail fast. Never fails on an API
# error or a missing run: dispatch can lag, and the producer's own health is a
# hint here, not the authority. The release itself is the authority.
check_producer() {
  local attempt="$1" state="" rc=0 run_status run_conclusion run_url

  state=$(producer_state "$INPUT_REPO" "$WORKFLOW" "$INPUT_VERSION") || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 0
  fi

  IFS='|' read -r run_status run_conclusion run_url <<<"$state"

  if is_terminal "$run_conclusion"; then
    echo "::error::${WORKFLOW} for ${INPUT_VERSION} in ${INPUT_REPO} already concluded ${run_conclusion}; release ${INPUT_VERSION} will never appear"
    echo "::error::failed producer run: ${run_url}"
    echo "::error::re-run that workflow first, then re-run this job - re-running this job alone cannot succeed"
    return 1
  fi

  if [ "$run_status" = "completed" ] && [ "$run_conclusion" = "success" ]; then
    success_absent=$((success_absent + 1))
    if [ "$success_absent" -ge "$SUCCESS_ABSENT_GRACE" ]; then
      echo "::error::${WORKFLOW} for ${INPUT_VERSION} in ${INPUT_REPO} succeeded but release ${INPUT_VERSION} is still absent after ${success_absent} polls"
      echo "::error::producer run: ${run_url}"
      return 1
    fi
    echo "producer succeeded but release not readable yet (${success_absent}/${SUCCESS_ABSENT_GRACE})"
    return 0
  fi

  echo "attempt ${attempt}/${MAX_ATTEMPTS}: producer run is ${run_status}, still waiting"
  return 0
}

main() {
  local attempt rc api_failures=0 api_failures_total=0 waited=0
  success_absent=0

  echo "waiting for release ${INPUT_VERSION} in ${INPUT_REPO} (up to ${MAX_ATTEMPTS} x ${INTERVAL_SECONDS}s)..."
  [ -n "$WORKFLOW" ] && echo "producer workflow: ${WORKFLOW} (will fail fast if it already failed)"

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    rc=0
    release_present "$INPUT_REPO" "$INPUT_VERSION" || rc=$?

    case "$rc" in
    0)
      echo "release ${INPUT_VERSION} present in ${INPUT_REPO} after attempt ${attempt}"
      emit waited-seconds "$waited"
      emit release-url "https://github.com/${INPUT_REPO}/releases/tag/${INPUT_VERSION}"
      return 0
      ;;
    1)
      api_failures=0
      ;;
    *)
      api_failures=$((api_failures + 1))
      api_failures_total=$((api_failures_total + 1))
      echo "::warning::attempt ${attempt}/${MAX_ATTEMPTS}: release lookup failed (${api_failures}/${MAX_API_FAILURES} consecutive)"
      if [ "$api_failures" -ge "$MAX_API_FAILURES" ]; then
        echo "::error::giving up after ${api_failures} consecutive API failures looking up ${INPUT_VERSION} in ${INPUT_REPO}"
        return 1
      fi
      ;;
    esac

    if [ -n "$WORKFLOW" ] && [ "$rc" -eq 1 ]; then
      check_producer "$attempt" || return 1
    fi

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
      sleep "$INTERVAL_SECONDS"
      waited=$((waited + INTERVAL_SECONDS))
    fi
  done

  # The consecutive counter resets on every clean 404, so a partial outage that
  # alternates errors with real 404s (intermittent rate-limiting, say) never
  # trips the circuit breaker and the wait spends its whole budget. That is the
  # safe direction to fail, but the timeout alone would read as "the producer
  # was slow" when the truth is "we could barely see the API". Report the
  # cumulative count so the two are distinguishable.
  if [ "$api_failures_total" -gt 0 ]; then
    echo "::warning::${api_failures_total} of ${MAX_ATTEMPTS} release lookups failed with an API error; the API was degraded for part or all of this wait"
  fi
  echo "::error::release ${INPUT_VERSION} never appeared in ${INPUT_REPO} after ${MAX_ATTEMPTS} attempts (~$((MAX_ATTEMPTS * INTERVAL_SECONDS))s)"
  return 1
}

# Only auto-run when executed directly; sourcing (e.g. from bats) must not.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

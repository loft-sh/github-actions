#!/usr/bin/env bash
# finish mode: resolve the terminal outcome and complete the check-run opened by
# start mode.
#
# Inputs (env):
#   INPUT_CHECK_RUN_ID       id from start mode; empty means there is nothing to
#                            finish, which is the normal path for a comment that
#                            was not a command
#   INPUT_REPO               owner/name
#   INPUT_REPORT_CONCLUSION  what the test run declared about itself, if it got
#                            far enough to declare anything
#   INPUT_BUILD_RESULT       needs.<build>.result
#   INPUT_SUITE_RESULT       needs.<suite>.result
#   INPUT_SUMMARY            markdown for the check-run body
#   INPUT_DETAILS_URL        where the check-run should link
#   GH_TOKEN                 token for gh
#
# Output: conclusion — what was published, so the caller can reuse it in a
# comment without recomputing the matrix.
set -euo pipefail

# shellcheck source=.github/actions/comment-triggered-check/src/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

check_run_id="${INPUT_CHECK_RUN_ID:-}"
repo="${INPUT_REPO:?INPUT_REPO required}"
report="${INPUT_REPORT_CONCLUSION:-}"
build_result="${INPUT_BUILD_RESULT:-}"
suite_result="${INPUT_SUITE_RESULT:-}"
summary="${INPUT_SUMMARY:-}"
details_url="${INPUT_DETAILS_URL:-}"

# No check was opened, so there is nothing to close. This is not an error: the
# workflow fires on every comment, and most of them never reach start mode's
# create step. The caller should also guard on the id, but a guard that exists
# in only one place is a guard that gets dropped in a refactor.
if [[ -z "$check_run_id" ]]; then
  echo "no check-run to finish"
  emit "conclusion" ""
  exit 0
fi

conclusion="$(resolve_conclusion "$report" "$build_result" "$suite_result")"

case "$conclusion" in
  success) title="Passed" ;;
  neutral) title="Nothing to run" ;;
  cancelled) title="Cancelled" ;;
  timed_out) title="Timed out" ;;
  *) title="Failed" ;;
esac

if [[ -z "$summary" ]]; then
  summary="Build: ${build_result:-unknown}. Suite: ${suite_result:-unknown}."
fi

# Same reason as start mode: GitHub overrides details_url for this app, so the
# completed check would otherwise offer no way back to the logs. Appended rather
# than replacing, because the caller's summary is the useful part.
if [[ -n "$details_url" ]]; then
  summary="${summary}"$'\n\n'"[View the run](${details_url})"
fi

args=(--method PATCH "repos/${repo}/check-runs/${check_run_id}"
  -f "status=completed"
  -f "conclusion=${conclusion}"
  -f "output[title]=${title}"
  -f "output[summary]=${summary}")

if [[ -n "$details_url" ]]; then
  args+=(-f "details_url=${details_url}")
fi

# Retry, because this is the last chance to close the check. Nothing else will:
# there is no reconciliation pass, by design (see the README), so a check left
# in_progress here stays that way until a human intervenes, and anything that
# waits on every check-run of a commit waits on it forever. A transient API
# failure is the common case and a retry costs nothing.
attempts="${INPUT_PATCH_ATTEMPTS:-3}"
delay="${INPUT_PATCH_DELAY_SECONDS:-2}"
published=0
for ((attempt = 1; attempt <= attempts; attempt++)); do
  if gh api "${args[@]}" >/dev/null 2>&1; then
    published=1
    break
  fi
  if [[ "$attempt" -lt "$attempts" ]]; then
    echo "::warning::could not complete check-run ${check_run_id} (attempt ${attempt}/${attempts}); retrying"
    sleep "$delay"
  fi
done

if [[ "$published" -eq 0 ]]; then
  # Accepted residual risk, stated rather than hidden: after this the check-run
  # is stuck in_progress and only a human can clear it. The alternative was a
  # reconciliation pass on the next command, which cost three API calls and a
  # state machine whose own failure modes were worse.
  #
  # The recovery instruction has to be precise. "Re-run failed jobs" re-runs
  # only this job, and the check-run id it needs comes from a successful job
  # whose outputs are preserved, so the same check is closed. Re-running ALL
  # jobs would run start again and open a second check-run for the same filter.
  echo "::error::could not complete check-run ${check_run_id} after ${attempts} attempts; it is stuck in progress and will block anything waiting on this commit's checks. Use \"Re-run failed jobs\" to retry just this job, not \"Re-run all jobs\" which would open a second check-run, or close the check by hand."
  exit 1
fi

# An adopted check-run drops out of the pull request's view if the suite that
# adopted it re-runs while ours is still in progress. Republish an identical
# completed one. Best effort: the verdict is already published above.
republish_if_hidden() {
  local detail name head_sha create_args

  detail="$(gh api "repos/${repo}/check-runs/${check_run_id}" 2>/dev/null)" || return 0
  name="$(printf '%s' "$detail" | jq -r '.name // ""')"
  head_sha="$(printf '%s' "$detail" | jq -r '.head_sha // ""')"
  [[ -n "$name" && -n "$head_sha" ]] || return 0

  # No filter argument, so this is `latest`, which is what the pull request
  # renders. One page only: past a hundred checks on one commit, a spurious
  # duplicate row is a better failure than an unbounded number of API calls.
  if gh api "repos/${repo}/commits/${head_sha}/check-runs?per_page=100" 2>/dev/null \
    | jq -r '.check_runs[].id' | grep -qx "$check_run_id"; then
    return 0
  fi

  echo "::warning::check-run ${check_run_id} is no longer displayed on ${head_sha}; republishing the same verdict"
  create_args=(--method POST "repos/${repo}/check-runs"
    -f "name=${name}"
    -f "head_sha=${head_sha}"
    -f "status=completed"
    -f "conclusion=${conclusion}"
    -f "output[title]=${title}"
    -f "output[summary]=${summary}")
  [[ -n "$details_url" ]] && create_args+=(-f "details_url=${details_url}")

  gh api "${create_args[@]}" >/dev/null 2>&1 ||
    echo "::warning::could not republish check-run ${check_run_id}"
}

republish_if_hidden

echo "::notice::published ${conclusion} to check-run ${check_run_id}"
emit "conclusion" "$conclusion"

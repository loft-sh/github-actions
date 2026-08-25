#!/usr/bin/env bats
# Invocation-level tests for finish.sh against a stubbed gh.
#
# This is the completion boundary for the custom check-run. If it publishes the
# wrong conclusion the pull request shows a wrong verdict, and if it publishes
# nothing the check is stuck in progress, so both halves are pinned here rather
# than only in the pure matrix tests.

load gh_mock

SCRIPT="$BATS_TEST_DIRNAME/../src/finish.sh"

setup() {
  setup_gh_mock
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  export INPUT_REPO="loft-sh/demo"
  export INPUT_CHECK_RUN_ID="4242"
  export INPUT_REPORT_CONCLUSION=""
  export INPUT_BUILD_RESULT="success"
  export INPUT_SUITE_RESULT="success"
  export INPUT_SUMMARY=""
  export INPUT_DETAILS_URL=""
  # Keep retries fast; the retry count itself is asserted below.
  export INPUT_PATCH_DELAY_SECONDS="0"
  export GH_TOKEN="x"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
  teardown_gh_mock
}

kv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-; }
patches() { calls_matching "PATCH"; }

# --- the no-op path ----------------------------------------------------------

@test "an empty check-run id is a no-op, not an error" {
  export INPUT_CHECK_RUN_ID=""
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv conclusion)" = "" ]
  [ "$(call_count)" -eq 0 ]
}

# --- conclusion propagation --------------------------------------------------

@test "a report conclusion is published verbatim" {
  export INPUT_REPORT_CONCLUSION="success"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv conclusion)" = "success" ]
  [ "$(patches)" -eq 1 ]
  [ "$(calls_matching "conclusion=success")" -eq 1 ]
}

@test "neutral from the report reaches the API" {
  export INPUT_REPORT_CONCLUSION="neutral"
  run bash "$SCRIPT"
  [ "$(kv conclusion)" = "neutral" ]
  [ "$(calls_matching "conclusion=neutral")" -eq 1 ]
}

@test "a skipped suite with no report publishes failure, not neutral" {
  export INPUT_SUITE_RESULT="skipped"
  run bash "$SCRIPT"
  [ "$(kv conclusion)" = "failure" ]
  [ "$(calls_matching "conclusion=failure")" -eq 1 ]
}

@test "a cancelled run publishes cancelled" {
  export INPUT_BUILD_RESULT="cancelled"
  export INPUT_SUITE_RESULT="skipped"
  run bash "$SCRIPT"
  [ "$(kv conclusion)" = "cancelled" ]
  [ "$(calls_matching "conclusion=cancelled")" -eq 1 ]
}

@test "an unrecognised report conclusion publishes failure" {
  export INPUT_REPORT_CONCLUSION="action_required"
  run bash "$SCRIPT"
  [ "$(kv conclusion)" = "failure" ]
  [ "$(calls_matching "conclusion=action_required")" -eq 0 ]
}

@test "the title matches the conclusion" {
  export INPUT_REPORT_CONCLUSION="timed_out"
  run bash "$SCRIPT"
  [ "$(calls_matching "Timed out")" -eq 1 ]
}

# --- wiring ------------------------------------------------------------------

@test "the details url is passed through when given" {
  export INPUT_DETAILS_URL="https://example.test/run/1"
  run bash "$SCRIPT"
  [ "$(calls_matching "details_url=https://example.test/run/1")" -eq 1 ]
}

@test "no details url means the flag is omitted rather than sent empty" {
  run bash "$SCRIPT"
  [ "$(calls_matching "details_url=")" -eq 0 ]
}

@test "a caller summary overrides the default" {
  export INPUT_SUMMARY="17 specs failed"
  run bash "$SCRIPT"
  [ "$(calls_matching "17 specs failed")" -eq 1 ]
}

@test "the default summary reports both job results" {
  export INPUT_SUITE_RESULT="failure"
  run bash "$SCRIPT"
  [ "$(calls_matching "Suite: failure")" -eq 1 ]
}

@test "it patches the check-run named by the input" {
  run bash "$SCRIPT"
  [ "$(calls_matching "PATCH repos/loft-sh/demo/check-runs/4242")" -eq 1 ]
}

# --- the failure that leaves a stuck check ----------------------------------

@test "a failing patch is retried and then reported as an error" {
  export GH_MOCK_PATCH_FAIL=1
  export INPUT_PATCH_ATTEMPTS="3"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(patches)" -eq 3 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"stuck in progress"* ]]
}

@test "the error names a recovery path rather than a removed mechanism" {
  export GH_MOCK_PATCH_FAIL=1
  export INPUT_PATCH_ATTEMPTS="1"
  run bash "$SCRIPT"
  [[ "$output" != *"reconcile"* ]]
}

# Re-running everything would run start again and open a second check-run for
# the same filter, so the instruction has to name the narrower option.
@test "the recovery instruction points at re-running only the failed job" {
  export GH_MOCK_PATCH_FAIL=1
  export INPUT_PATCH_ATTEMPTS="1"
  run bash "$SCRIPT"
  [[ "$output" == *"Re-run failed jobs"* ]]
  [[ "$output" == *"second check-run"* ]]
}

@test "a single configured attempt makes exactly one call" {
  export GH_MOCK_PATCH_FAIL=1
  export INPUT_PATCH_ATTEMPTS="1"
  run bash "$SCRIPT"
  [ "$(patches)" -eq 1 ]
}

@test "no conclusion output is emitted when publishing failed" {
  export GH_MOCK_PATCH_FAIL=1
  export INPUT_PATCH_ATTEMPTS="1"
  run bash "$SCRIPT"
  [ "$(kv conclusion)" = "" ]
}

# --- the link back to the logs -----------------------------------------------
# details_url is overridden by GitHub for this app, so the summary is the only
# place a link survives. See the note in start.sh.

@test "the completed check-run links to the run from its summary" {
  export INPUT_DETAILS_URL="https://github.com/loft-sh/demo/actions/runs/999"
  run bash "$SCRIPT"
  [ "$(calls_matching 'View the run.*actions/runs/999')" -ge 1 ]
}

@test "the caller's summary is kept and the link appended, not replaced" {
  export INPUT_DETAILS_URL="https://github.com/loft-sh/demo/actions/runs/999"
  export INPUT_SUMMARY="Suite reported 12 failures."
  run bash "$SCRIPT"
  [ "$(calls_matching 'Suite reported 12 failures.*View the run')" -ge 1 ]
}

@test "no details url means no link rather than a broken one" {
  run bash "$SCRIPT"
  [ "$(calls_matching 'View the run')" -eq 0 ]
}

# --- republishing a check-run that stopped being displayed -------------------
#
# A check-run created here is adopted into another workflow's check suite. If
# that suite re-runs mid-flight ours stays in the old attempt and the pull
# request stops rendering it, so the verdict is published but invisible.

creates() { calls_matching "method POST repos/loft-sh/demo/check-runs"; }

@test "a still-displayed check-run is not republished" {
  export GH_MOCK_LATEST_IDS="4242 99"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
}

@test "a hidden check-run is republished" {
  export GH_MOCK_LATEST_IDS="99 100"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 1 ]
  [[ "$output" == *"no longer displayed"* ]]
}

@test "the republished check carries the same name and verdict" {
  export GH_MOCK_LATEST_IDS="99"
  export INPUT_SUITE_RESULT="failure"
  run bash "$SCRIPT"
  [ "$(calls_matching "name=e2e-pro: snapshots")" -eq 1 ]
  [ "$(calls_matching "method POST.*conclusion=failure")" -eq 1 ]
  [ "$(calls_matching "method POST.*status=completed")" -eq 1 ]
}

@test "an empty listing counts as hidden" {
  export GH_MOCK_LATEST_IDS=""
  run bash "$SCRIPT"
  [ "$(creates)" -eq 1 ]
}

@test "a failed lookup skips republishing without failing the run" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_CHECKRUN_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  [ "$(kv conclusion)" = "success" ]
}

@test "a malformed lookup skips republishing without losing the published conclusion" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_CHECKRUN_JSON='not json at all'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  [ "$(kv conclusion)" = "success" ]
}

@test "a wrong-shaped lookup skips republishing without losing the published conclusion" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_CHECKRUN_JSON='{"id":4242,"name":"e2e-pro: snapshots","head_sha":"abc123","app":"unexpected"}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  [ "$(kv conclusion)" = "success" ]
}

@test "a failed republish warns but does not fail the run" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LATEST_IDS="99"
  export GH_MOCK_CREATE_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not republish"* ]]
  [ "$(kv conclusion)" = "success" ]
}

@test "republishing never runs when the patch itself failed" {
  export GH_MOCK_LATEST_IDS="99"
  export GH_MOCK_PATCH_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(creates)" -eq 0 ]
}

# A failed or unparseable listing is not evidence the check is hidden. Creating
# on either would publish a duplicate without establishing anything.

@test "a failed listing request does not republish" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_FAIL=1
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  [[ "$output" == *"could not list the check-runs"* ]]
  [ "$(kv conclusion)" = "success" ]
}

@test "an unparseable listing does not republish" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_JSON='not json at all'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  [[ "$output" == *"unexpected check-runs response"* ]]
}

@test "a listing without the check_runs key does not republish" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_JSON='{"message":"Not Found"}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  [[ "$output" == *"unexpected check-runs response"* ]]
}

@test "a scalar listing body does not republish" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_JSON='42'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
}

@test "a well-formed empty listing still republishes" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_JSON='{"check_runs":[]}'
  run bash "$SCRIPT"
  [ "$(creates)" -eq 1 ]
}

# --- a newer check with the same name is the replacement ---------------------
#
# A repeated command opens a second check-run under the same name, and `latest`
# omits the older id on purpose. Republishing there would make the superseded
# verdict the newest one and bury the replacement's result.

@test "a newer completed check with the same name suppresses republishing" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_JSON='{"check_runs":[{"id":9001,"name":"e2e-pro: snapshots","app":{"id":1},"status":"completed","conclusion":"success"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  [[ "$output" == *"superseded by a newer check"* ]]
}

@test "a newer in-progress check with the same name suppresses republishing" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_JSON='{"check_runs":[{"id":9002,"name":"e2e-pro: snapshots","app":{"id":1},"status":"in_progress"}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
}

# The supersede shape from the live integration run: the cancelled original is
# absent from `latest`, the successful replacement is present.
@test "a cancelled run does not overwrite the replacement that superseded it" {
  export INPUT_BUILD_RESULT="cancelled"
  export INPUT_SUITE_RESULT="skipped"
  export GH_MOCK_LIST_JSON='{"check_runs":[{"id":9003,"name":"e2e-pro: snapshots","app":{"id":1},"status":"completed","conclusion":"success"}]}'
  run bash "$SCRIPT"
  [ "$(kv conclusion)" = "cancelled" ]
  [ "$(creates)" -eq 0 ]
}

@test "a same-name check from another app does not suppress republishing" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_JSON='{"check_runs":[{"id":9004,"name":"e2e-pro: snapshots","app":{"id":77}}]}'
  run bash "$SCRIPT"
  [ "$(creates)" -eq 1 ]
}

@test "a different name in the listing still republishes" {
  export INPUT_REPORT_CONCLUSION="success"
  export GH_MOCK_LIST_JSON='{"check_runs":[{"id":9005,"name":"Suite / E2E Tests","app":{"id":1}}]}'
  run bash "$SCRIPT"
  [ "$(creates)" -eq 1 ]
}

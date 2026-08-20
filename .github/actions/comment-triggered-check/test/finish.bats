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
  [ "$(calls_matching "check-runs/4242")" -eq 1 ]
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

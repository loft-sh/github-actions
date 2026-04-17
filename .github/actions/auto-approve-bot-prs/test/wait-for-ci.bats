#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/wait-for-ci.sh"
load gh_mock

setup() {
  setup_gh_mock
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_REPOSITORY="owner/repo"
  export PR_HEAD_SHA="deadbeef"
  export SELF_RUN_ID="111111"
  export WAIT_MAX_ATTEMPTS=2
  export WAIT_SLEEP_SECONDS=1
}
teardown() { rm -f "$GITHUB_OUTPUT"; teardown_gh_mock; }

kv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1; }

@test "no check-runs → ci_green=true" {
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "only self check-run → ci_green=true" {
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[{"status":"in_progress","conclusion":null,"details_url":"https://github.com/o/r/actions/runs/111111/job/1"}]}' \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "all other checks success → ci_green=true" {
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"status":"completed","conclusion":"success","details_url":"https://github.com/o/r/actions/runs/222/job/1"},
    {"status":"completed","conclusion":"skipped","details_url":"https://github.com/o/r/actions/runs/333/job/1"},
    {"status":"completed","conclusion":"neutral","details_url":"https://github.com/o/r/actions/runs/444/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "any other check failed → ci_green=false" {
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"status":"completed","conclusion":"success","details_url":"https://github.com/o/r/actions/runs/222/job/1"},
    {"status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/333/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
}

@test "other check still pending exceeds attempts → ci_green=false (timeout)" {
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"status":"in_progress","conclusion":null,"details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
}

@test "self check pending but other check passed → ci_green=true" {
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"status":"in_progress","conclusion":null,"details_url":"https://github.com/o/r/actions/runs/111111/job/1"},
    {"status":"completed","conclusion":"success","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "missing PR_HEAD_SHA fails" {
  run env -u PR_HEAD_SHA GITHUB_OUTPUT="$GITHUB_OUTPUT" GITHUB_REPOSITORY=o/r SELF_RUN_ID=1 "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "superseded cancelled attempt does not block when latest attempt is green" {
  # Same check name ('integration-test/chrome') appears twice: an older
  # attempt that was cancelled (e.g. by a rerun), and a newer attempt that
  # landed on skipped. Dedupe-by-name must pick the latest, otherwise a
  # stale cancelled from a superseded run silently blocks approval.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"integration-test/chrome","status":"completed","conclusion":"cancelled","started_at":"2026-04-17T05:00:00Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"integration-test/chrome","status":"completed","conclusion":"skipped","started_at":"2026-04-17T06:00:00Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "cancelled as latest attempt still blocks (not a stale artifact)" {
  # Opposite of the superseded case: when cancelled IS the latest attempt,
  # it is a real signal that CI was aborted and approval should not proceed.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"integration-test/chrome","status":"completed","conclusion":"skipped","started_at":"2026-04-17T05:00:00Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"integration-test/chrome","status":"completed","conclusion":"cancelled","started_at":"2026-04-17T06:00:00Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
}

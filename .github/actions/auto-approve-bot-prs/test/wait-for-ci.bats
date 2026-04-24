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
  export WAIT_MIN_ATTEMPTS=1
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

@test "identical started_at with differing ids → id tiebreak picks newer (higher id)" {
  # Real-world case observed on loft-sh/vcluster-docs PR #1992: the Integration
  # Tests workflow ran twice for the same PR head; concurrency cancellation
  # and the winning run both started within the same second, so started_at
  # alone is ambiguous. GitHub allocates check-run ids monotonically, so id
  # tiebreaks unambiguously toward the newer attempt.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"Safari (macOS)","id":100,"status":"completed","conclusion":"cancelled","started_at":"2026-04-23T06:35:09Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"Safari (macOS)","id":200,"status":"completed","conclusion":"skipped","started_at":"2026-04-23T06:35:09Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "identical started_at tiebreak is deterministic regardless of api order" {
  # Same as above but the API returned the attempts in the opposite order.
  # A stable sort on started_at alone would let input order decide the winner
  # and silently flip the verdict between runs.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"Safari (macOS)","id":200,"status":"completed","conclusion":"skipped","started_at":"2026-04-23T06:35:09Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"},
    {"name":"Safari (macOS)","id":100,"status":"completed","conclusion":"cancelled","started_at":"2026-04-23T06:35:09Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

# ---------------------------------------------------------------------------
# Commit-status polling (catches Netlify and other legacy-CI signals)

@test "commit status failure blocks approval even when check-runs are clean" {
  # Real-world case observed on loft-sh/vcluster-docs PR #2009: Netlify's
  # "deploy/netlify" commit status was failing while every GitHub-native
  # check-run passed. Ignoring the statuses API let the bot approve broken CI.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"lint","status":"completed","conclusion":"success","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' \
  GH_MOCK_STATUSES_JSON='{"state":"failure","statuses":[
    {"context":"deploy/netlify","state":"failure","target_url":"https://app.netlify.com/projects/x/deploys/abc"}
  ]}' \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"deploy/netlify"* ]]
}

@test "commit status error also blocks approval" {
  GH_MOCK_STATUSES_JSON='{"state":"error","statuses":[
    {"context":"ci/circleci","state":"error","target_url":"https://circleci.com/x/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"ci/circleci"* ]]
}

@test "pending commit status keeps the job waiting past first poll" {
  # With MIN_ATTEMPTS=1 we'd otherwise declare green immediately. A pending
  # commit status must behave just like a pending check-run: keep polling.
  GH_MOCK_STATUSES_JSON='{"state":"pending","statuses":[
    {"context":"deploy/netlify","state":"pending","target_url":"https://app.netlify.com/x/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
}

@test "successful commit status combined with clean check-runs → ci_green=true" {
  GH_MOCK_STATUSES_JSON='{"state":"success","statuses":[
    {"context":"deploy/netlify","state":"success","target_url":"https://app.netlify.com/x/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

# ---------------------------------------------------------------------------
# Minimum-attempt settle period (keeps slow external checks from being missed)

@test "min_attempts floor forces extra polls before declaring green" {
  # With MAX=2 and MIN=2 we should never short-circuit on the first poll;
  # the run must poll at least twice before green. If min_attempts is not
  # honored the loop would exit at attempt 1 because pending=0.
  export WAIT_MIN_ATTEMPTS=2
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
  # Two check-runs calls + two statuses calls = 4 api calls total.
  [ "$(grep -c '^api' "$GH_MOCK_CALLS")" -eq 4 ]
}

@test "min_attempts cannot exceed max_attempts (timeout wins)" {
  # If min > max, the loop exhausts attempts before ever being eligible to
  # declare green, so the timeout branch emits ci_green=false. This models
  # the caller-misconfiguration case (min=99, max=2) defensively.
  export WAIT_MIN_ATTEMPTS=99
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
}

# ---------------------------------------------------------------------------
# Regression tests — these are the tests that SHOULD have existed before
# loft-sh/vcluster-docs#2009 shipped a false-green approval. Each one fails
# against the pre-fix script (either because commit statuses were ignored or
# because an empty first poll short-circuited to ci_green=true).

@test "regression: pr #2009 — failing check-runs arrive after initial empty polls" {
  # Reproduces the #2009 timeline: at T+3s auto-approve observed zero signals
  # on the PR head because external CI had not yet registered. The failing
  # check-runs arrived 114s later. Old code exited green on the first poll;
  # the settle floor must keep the loop alive long enough for the failure
  # to be observed.
  #
  # Not Netlify-specific — this is the generic 'any CI posts a failure while
  # we were in our settle window' contract. Name values are illustrative.
  export WAIT_MIN_ATTEMPTS=5
  export WAIT_MAX_ATTEMPTS=6

  # Sequence file: one compact JSON response per line. Polls 1-4 observe an
  # empty head (external CI silent); polls 5-6 observe the failures that
  # finally landed. Matches #2009's 'bot approved before checks registered'.
  export GH_MOCK_CHECK_RUNS_SEQ="$MOCK_DIR/cr_seq"
  {
    echo '{"check_runs":[]}'
    echo '{"check_runs":[]}'
    echo '{"check_runs":[]}'
    echo '{"check_runs":[]}'
    echo '{"check_runs":[{"name":"Redirect rules","status":"completed","conclusion":"failure","details_url":"https://external-ci/x/1"},{"name":"Header rules","status":"completed","conclusion":"failure","details_url":"https://external-ci/x/2"},{"name":"Pages changed","status":"completed","conclusion":"failure","details_url":"https://external-ci/x/3"}]}'
    echo '{"check_runs":[{"name":"Redirect rules","status":"completed","conclusion":"failure","details_url":"https://external-ci/x/1"},{"name":"Header rules","status":"completed","conclusion":"failure","details_url":"https://external-ci/x/2"},{"name":"Pages changed","status":"completed","conclusion":"failure","details_url":"https://external-ci/x/3"}]}'
  } > "$GH_MOCK_CHECK_RUNS_SEQ"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  # Every failing check name must appear in the log so audits can find
  # which integration blocked the approval.
  [[ "$output" == *"Redirect rules"* ]]
  [[ "$output" == *"Header rules"* ]]
  [[ "$output" == *"Pages changed"* ]]
}

@test "regression: pr #2009 — commit-status failure arrives during settle window" {
  # Same race as above, different API surface. Pre-fix code polled only
  # /check-runs, so any CI that reports exclusively via /status (Netlify,
  # legacy CI integrations) was completely invisible to the waiter.
  export WAIT_MIN_ATTEMPTS=4
  export WAIT_MAX_ATTEMPTS=5

  export GH_MOCK_STATUSES_SEQ="$MOCK_DIR/st_seq"
  {
    echo '{"state":"success","statuses":[]}'
    echo '{"state":"success","statuses":[]}'
    echo '{"state":"success","statuses":[]}'
    echo '{"state":"failure","statuses":[{"context":"deploy/netlify","state":"failure","target_url":"https://external-ci/deploys/abc"}]}'
    echo '{"state":"failure","statuses":[{"context":"deploy/netlify","state":"failure","target_url":"https://external-ci/deploys/abc"}]}'
  } > "$GH_MOCK_STATUSES_SEQ"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"deploy/netlify"* ]]
}

@test "regression: empty first poll must not short-circuit to green at default settle" {
  # The core defect: treating 'nothing visible' as 'all checks passed'.
  # With the default min_attempts (12) and a tight max_attempts budget, an
  # initially-empty PR must NOT get instant approval. The pre-fix script
  # returned ci_green=true on attempt 1 with no external checks visible.
  unset WAIT_MIN_ATTEMPTS  # exercise the in-script default (12)
  export WAIT_MAX_ATTEMPTS=3
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' \
  GH_MOCK_STATUSES_JSON='{"state":"success","statuses":[]}' \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  # With max(3) < default-min(12) the run must time out, not approve. This
  # is a direct regression guard: if anyone lowers the default, this test
  # flips to ci_green=true and the CI job fails.
  [ "$(kv ci_green)" = "ci_green=false" ]
}

@test "regression: mixed signal — check-run green + commit status failure blocks" {
  # Defensive case: all GitHub-native check-runs are clean, but a single
  # commit-status context is failing. Pre-fix code saw only the check-runs
  # side and approved. The gate must be a logical AND across both surfaces.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"lint","status":"completed","conclusion":"success","details_url":"https://github.com/o/r/actions/runs/222/job/1"},
    {"name":"tests","status":"completed","conclusion":"success","details_url":"https://github.com/o/r/actions/runs/333/job/1"}
  ]}' \
  GH_MOCK_STATUSES_JSON='{"state":"failure","statuses":[
    {"context":"deploy/netlify","state":"failure","target_url":"https://app.netlify.com/x/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"deploy/netlify"* ]]
}

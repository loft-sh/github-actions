#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/wait-for-ci.sh"
load gh_mock
load assertions

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

@test "cancelled as latest attempt still blocks once settle period elapses" {
  # Opposite of the superseded case: when cancelled IS the latest attempt,
  # it is a real signal that CI was aborted and approval should not proceed.
  # The script holds the cancelled state across the settle floor in case a
  # concurrency-triggered replacement is en route (see #2019/#2020 race);
  # past the floor (here min=1) it bails.
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

@test "default-deny: check-runs API failure must never emit ci_green=true" {
  # Silent API errors are the same defect class as #2009: absence of signal
  # treated as absence of problem. If gh can't reach the API, we cannot prove
  # CI is clean — we must refuse to approve rather than default to green.
  export WAIT_MAX_ATTEMPTS=3
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_FAIL=always run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
}

@test "default-deny: statuses API failure must never emit ci_green=true" {
  export WAIT_MAX_ATTEMPTS=3
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_STATUSES_FAIL=always run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
}

@test "regression: devops-1254 — check-runs API error surfaces gh's stderr, not just 'API failed'" {
  # The v0.36.1 cut stalled ~70 min because this line said only "check-runs API
  # failed". A permanent 403 (the CI-read token cannot reach the Checks API) and
  # a transient blip produced byte-identical logs and identical default-deny
  # exits, so the misconfiguration was undiagnosable from CI output.
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_FAIL=always run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"check-runs API failed"* ]]
  [[ "$output" == *"mock: check-runs forced failure"* ]]
}

@test "regression: devops-1254 — statuses API error also surfaces gh's stderr" {
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_STATUSES_FAIL=always run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"statuses API failed"* ]]
  [[ "$output" == *"mock: statuses forced failure"* ]]
}

@test "regression: devops-1254 — giving up is an ::error:: carrying the last error and the fix" {
  # Escalated from ::notice::. The job keeps continue-on-error so this still
  # cannot turn a caller's CI red, but a run that refused to approve must not
  # read as clean — something downstream may be blocking on the merge.
  export WAIT_MAX_ATTEMPTS=5
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_FAIL=always run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"::error::Too many consecutive API errors"* ]]
  [[ "$output" == *"Last error: mock: check-runs forced failure"* ]]
  # The actionable half: names the Checks API and the caller-permission trap.
  [[ "$output" == *"Checks API"* ]]
  [[ "$output" == *"checks: read"* ]]
  [[ "$output" == *"CALLER"* ]]
}

@test "regression: devops-1254 — a recovered poll clears the stale error text" {
  export WAIT_MAX_ATTEMPTS=3
  export WAIT_MIN_ATTEMPTS=1
  seq_file="$(mktemp)"
  printf 'ERROR\n{"check_runs":[]}\n' > "$seq_file"
  GH_MOCK_CHECK_RUNS_SEQ="$seq_file" run "$SCRIPT"
  rm -f "$seq_file"
  [ "$status" -eq 0 ]
  # Attempt 1 errors and says so; attempt 2 succeeds and reaches a verdict.
  [[ "$output" == *"attempt 1/3: check-runs API failed"* ]]
  [[ "$output" == *"sequenced check-runs error"* ]]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "regression: devops-1254 — a jq-parse failure must not report an earlier API error" {
  # The bug this replaces a weaker test for: last_error was set only on API
  # failure and never reset, so a later malformed-response poll inherited it and
  # the bail told the operator to go check token permissions for a fault that had
  # nothing to do with permissions. That is the exact misdiagnosis the error
  # reporting exists to prevent, reintroduced one layer up.
  #   poll 1-2: API error (sets last_error)
  #   poll 3-5: API succeeds but returns garbage (jq parse failure)
  export WAIT_MAX_ATTEMPTS=5
  export WAIT_MIN_ATTEMPTS=1
  seq_file="$(mktemp)"
  printf 'ERROR\nERROR\n{not json\n{not json\n{not json\n' > "$seq_file"
  GH_MOCK_CHECK_RUNS_SEQ="$seq_file" run "$SCRIPT"
  rm -f "$seq_file"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"check-runs jq parse failed"* ]]
  # The bail must describe the parse failure, NOT the long-gone API error.
  [[ "$output" == *"Last error: malformed check-runs response"* ]]
  [[ "$output" != *"Last error: mock: sequenced check-runs error"* ]]
}

@test "regression: devops-1254 — CR in api stderr cannot forge a workflow command" {
  # CR terminates a log line for the runner, so raw \r in API error text would
  # start a NEW line, and a line beginning '::' is a workflow command. Anything
  # the sanitizer lets through here is a log-injection primitive.
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_FAIL=always \
    GH_MOCK_STDERR='gh: HTTP 403 nope\r::error::FORGED\r::set-output name=x::y 100%\rtail' \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  # THE guard. A line-anchored grep cannot fail on a CR-delimited payload,
  # because grep splits on LF only while the runner also splits on CR — so an
  # unsanitized payload would satisfy '^::error::' checks and the test would
  # pass while the bug was live. Assert there is no CR in the output at all.
  assert_no_match '\r' "$output"
  # Belt and braces for the LF channel, which grep does see.
  assert_no_match '(?m)^::error::FORGED' "$output"
  # The text is still reported, flattened onto the one annotation line.
  [[ "$output" == *"HTTP 403 nope"* ]]
  [[ "$output" == *"tail"* ]]
  # '%' is escaped so the runner cannot decode %0A/%25 out of API-controlled text.
  [[ "$output" == *"100%25"* ]]
}

@test "regression: devops-1254 — a check-run NAME cannot forge a workflow command" {
  # The wider channel, and the one the first fix missed: check-run names and
  # commit-status contexts are written by whoever posted the check on the head
  # SHA, not by GitHub, and GitHub documents no character restriction on them.
  # They reach the failed/cancelled/pending log lines.
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON="$(printf '{"check_runs":[
    {"name":"evil\\r::error::INJECTED-VIA-NAME and %%0A%%25","status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}')" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::INJECTED' "$output"
  # Escaped, not decoded, and the name is still reported for diagnosis.
  [[ "$output" == *"%250A%2525"* ]]
  [[ "$output" == *"evil"* ]]
}

@test "regression: devops-1254 — a pending check NAME is sanitized too" {
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON="$(printf '{"check_runs":[
    {"name":"wait\\r::warning::INJECTED-PENDING","status":"in_progress","conclusion":null,"details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}')" run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::warning::INJECTED' "$output"
  [[ "$output" == *"pending:"* ]]
  # Positive: the ascii part of the name must survive. Without this, a sanitizer
  # that returned empty would yield "pending: <unnamed>" and still pass.
  [[ "$output" == *"wait"* ]]
}

@test "regression: devops-1254 — a cancelled check NAME is sanitized too" {
  export WAIT_MAX_ATTEMPTS=2
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON="$(printf '{"check_runs":[
    {"name":"gone\\r::error::INJECTED-CANCELLED","status":"completed","conclusion":"cancelled","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}')" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::INJECTED' "$output"
  # Positive: else an empty sanitizer result emits "Cancelled: " and still passes.
  [[ "$output" == *"gone"* ]]
}

@test "regression: devops-1254 — a commit-status CONTEXT cannot forge a workflow command" {
  # The other half of the hostile channel the script's comment names. Both the
  # check-run and status sides feed the same two log lines, but the NAME tests
  # only exercise cr_*_detail. Dropping the sanitizer from the status side alone
  # would ship an injection with a fully green suite.
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' \
  GH_MOCK_STATUSES_JSON="$(printf '{"state":"failure","statuses":[
    {"context":"deploy\\r::error::FORGED-VIA-STATUS-CONTEXT","state":"failure","target_url":"https://netlify.example/x"}
  ]}')" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
  [[ "$output" == *"deploy"* ]]
}

@test "regression: devops-1254 — a pending commit-status CONTEXT is sanitized too" {
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' \
  GH_MOCK_STATUSES_JSON="$(printf '{"state":"pending","statuses":[
    {"context":"queue\\r::warning::FORGED-PENDING-CONTEXT","state":"pending","target_url":"https://netlify.example/x"}
  ]}')" run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::warning::FORGED' "$output"
  [[ "$output" == *"queue"* ]]
}

@test "regression: devops-1254 — a non-numeric wait input must not hard-fail the script" {
  # `sleep "$sleep_seconds"` under set -e exited 1 with no ci_green at all,
  # which for a direct consumer of the composite is a red job. Inputs are
  # coerced now, so no caller value can break the exit-0 contract.
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  export WAIT_SLEEP_SECONDS="not-a-duration"
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"e2e","status":"in_progress","conclusion":null,"details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"WAIT_SLEEP_SECONDS='not-a-duration' is not an integer in 1..3600"* ]]
}

@test "regression: devops-1254 — the bail reports the FIRST error, not just the last" {
  # Four real 403s then one malformed response used to report only the parse
  # error, dropping the actionable fault from the summary.
  export WAIT_MAX_ATTEMPTS=5
  export WAIT_MIN_ATTEMPTS=1
  seq_file="$(mktemp)"
  printf 'ERROR\nERROR\nERROR\nERROR\n{not json\n' > "$seq_file"
  GH_MOCK_CHECK_RUNS_SEQ="$seq_file" \
    GH_MOCK_STDERR='gh: Resource not accessible by integration (HTTP 403)' \
    run "$SCRIPT"
  rm -f "$seq_file"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"Last error: malformed check-runs response"* ]]
  [[ "$output" == *"first error: gh: Resource not accessible by integration (HTTP 403)"* ]]
}

@test "regression: devops-1254 — realistic multiline gh 403 is flattened to one line" {
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_FAIL=always \
    GH_MOCK_STDERR='gh: Resource not accessible by personal access token (HTTP 403)\n{"message":"Resource not accessible"}' \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resource not accessible by personal access token (HTTP 403)"* ]]
  # Exactly one warning line for the attempt, not one per stderr line.
  [ "$(grep -c '::warning::attempt 1/1: check-runs API failed' <<<"$output")" -eq 1 ]
}

@test "regression: devops-1254 — non-ascii stderr does not break the length cap" {
  # cut -c is byte-based in a C locale, so a naive cap can split a UTF-8
  # sequence and emit invalid bytes into the annotation.
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  long="$(printf 'é%.0s' $(seq 1 400))"
  GH_MOCK_CHECK_RUNS_FAIL=always GH_MOCK_STDERR="gh: 403 ${long}" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"check-runs API failed"* ]]
  # Positive assertion first: without it, "no high bytes in the output" is
  # trivially satisfied by an implementation that discards stderr entirely, so
  # the test would pass against the very code it is meant to guard.
  [[ "$output" == *"gh: 403"* ]]
  # Non-ascii is dropped rather than truncated mid-character.
  assert_no_match '[\x80-\xff]' "$output"
}

@test "regression: devops-1254 — unusable TMPDIR must not hard-fail the script" {
  # action.yml promises the job never hard-fails, and a direct consumer of the
  # composite has no continue-on-error to hide behind. A bare mktemp assignment
  # under `set -e` exited 1 with no ci_green emitted at all.
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  TMPDIR=/proc/nonexistent run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
  [[ "$output" == *"could not allocate a temp file"* ]]
}

@test "regression: devops-1254 — first_error resets when the error streak resolves" {
  # Poll 1 errors, poll 2 succeeds, polls 3-7 fail to parse. The bail must not
  # attribute the streak to the long-resolved 403 from poll 1 — that is the F1
  # misattribution bug one variable over.
  export WAIT_MAX_ATTEMPTS=7
  export WAIT_MIN_ATTEMPTS=6
  seq_file="$(mktemp)"
  printf 'ERROR\n{"check_runs":[]}\n{bad\n{bad\n{bad\n{bad\n{bad\n' > "$seq_file"
  GH_MOCK_CHECK_RUNS_SEQ="$seq_file" \
    GH_MOCK_STDERR='gh: Resource not accessible by integration (HTTP 403)' \
    run "$SCRIPT"
  rm -f "$seq_file"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"Last error: malformed check-runs response"* ]]
  assert_no_match 'first error: gh: Resource not accessible' "$output"
}

@test "regression: devops-1254 — an out-of-range attempt count cannot hang the job" {
  # A valid but enormous integer used to be accepted (the boundary was int64
  # overflow in [ -gt ]), and `for attempt in $(seq 1 N)` then had to build the
  # whole list before the first poll: no output, no ci_green, hang until the
  # 6-hour job timeout. Strictly worse than the stall this script prevents.
  export WAIT_MAX_ATTEMPTS=9223372036854775807
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run timeout 60 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WAIT_MAX_ATTEMPTS='9223372036854775807' is not an integer in 1..100000"* ]]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "regression: devops-1254 — a non-numeric WAIT_MAX_ATTEMPTS is coerced, not fatal" {
  export WAIT_MAX_ATTEMPTS="lots"
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WAIT_MAX_ATTEMPTS='lots' is not an integer in 1..100000"* ]]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "regression: devops-1254 — a non-numeric WAIT_MIN_ATTEMPTS is coerced, not fatal" {
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS="soon"
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WAIT_MIN_ATTEMPTS='soon' is not an integer in 1..100000"* ]]
}

@test "regression: devops-1254 — a plausible fat-finger attempt count is also rejected" {
  export WAIT_MAX_ATTEMPTS=1000000000
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run timeout 60 "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not an integer in 1..100000"* ]]
}

@test "regression: devops-1254 — a rejected wait value cannot forge a workflow command" {
  export WAIT_SLEEP_SECONDS='x\r::error::FORGED-VIA-WAIT-INPUT'
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
}

@test "regression: devops-1254 — a long pending list is truncated with a marker, not severed" {
  # The 300-char cap is right for one hostile string and wrong for a legitimately
  # long list; this is the line the script's own comment calls out as how an
  # operator answers "why is this still running?".
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  json='{"check_runs":['
  for i in $(seq 1 20); do
    [ "$i" -gt 1 ] && json="${json},"
    json="${json}{\"name\":\"a-fairly-long-check-run-name-number-$(printf '%03d' "$i")\",\"status\":\"in_progress\",\"conclusion\":null,\"details_url\":\"https://github.com/o/r/actions/runs/2$i/job/1\"}"
  done
  json="${json}]}"
  GH_MOCK_CHECK_RUNS_JSON="$json" run "$SCRIPT"
  [ "$status" -eq 0 ]
  # All 20 survive at the wider list cap, so the diagnostic is actually useful.
  [[ "$output" == *"number-001"* ]]
  [[ "$output" == *"number-020"* ]]
}

@test "regression: devops-1254 — timing out is an ::error::, not a quiet notice" {
  # Sibling of the consecutive-error bail: a permanently-pending check, or errors
  # that never hit 5 in a row, exit here. A release cut blocking on the merge
  # deserves the same visibility.
  export WAIT_MAX_ATTEMPTS=2
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"e2e","status":"in_progress","conclusion":null,"details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"::error::Timed out waiting for other CI checks"* ]]
}

@test "default-deny: transient API errors do not count toward the settle floor" {
  # On the pre-TDD script an errored poll silently fell back to '[]' and still
  # counted as a settle attempt — with min_attempts=2 it would approve after
  # two failed polls because attempt>=min and 'pending=0'. The new contract:
  # errored polls do NOT advance the settle counter.
  export WAIT_MAX_ATTEMPTS=2
  export WAIT_MIN_ATTEMPTS=2
  GH_MOCK_CHECK_RUNS_FAIL=always run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
}

@test "pending check-run name is logged so operators can see what we are waiting on" {
  export WAIT_MAX_ATTEMPTS=1
  export WAIT_MIN_ATTEMPTS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"integration-tests","status":"in_progress","conclusion":null,"details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  # We expect the pending check name to appear somewhere in the output.
  [[ "$output" == *"integration-tests"* ]]
}

@test "failed check-run output includes the conclusion, not just the name" {
  # cancelled vs failure vs timed_out carry different debugging meaning. The
  # audit log should surface which kind of unsuccessful conclusion blocked
  # approval, so operators can tell a rerun-candidate from a real failure.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"e2e","status":"completed","conclusion":"timed_out","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"e2e"* ]]
  [[ "$output" == *"timed_out"* ]]
}

@test "regression: prs #2019/#2020 — cancelled at attempt 1 must wait for concurrency replacement" {
  # Reproduces the docs backport storm of 2026-04-27 where 4 sibling
  # backport PRs were created in 24s. GitHub's concurrency-group cancellation
  # marked the prior PR's browser-test workflow as `cancelled` and queued a
  # replacement, but the replacement took 5–10s to register. Pre-fix
  # wait-for-ci saw the cancelled check on attempt 1, treated it as a
  # terminal failure, and bailed before the replacement landed. The fix
  # holds the cancelled state across the settle floor so dedup can pick the
  # replacement once it shows up.
  export WAIT_MIN_ATTEMPTS=4
  export WAIT_MAX_ATTEMPTS=6

  cancelled='{"name":"Mobile Safari (iPhone)","id":100,"status":"completed","conclusion":"cancelled","started_at":"2026-04-27T07:40:05Z","details_url":"https://external/runs/220/job/1"}'
  replacement='{"name":"Mobile Safari (iPhone)","id":200,"status":"completed","conclusion":"skipped","started_at":"2026-04-27T07:40:15Z","details_url":"https://external/runs/221/job/1"}'

  # Polls 1-2: only the cancelled attempt is visible (the failure window).
  # One JSON object per PHYSICAL line — the mock serves a sequence entry with
  # `sed -n "${n}p"`, so a pretty-printed fixture arrives as an unparseable
  # fragment. This test used to be written that way: polls 3-4 errored out, the
  # sequence fell through to the empty default, and the green verdict came from
  # "no checks at all" rather than from dedup picking the replacement. It passed
  # without ever exercising the path it names.
  export GH_MOCK_CHECK_RUNS_SEQ="$MOCK_DIR/cr_seq"
  {
    printf '{"check_runs":[%s]}\n' "$cancelled"
    printf '{"check_runs":[%s]}\n' "$cancelled"
  } > "$GH_MOCK_CHECK_RUNS_SEQ"
  # Poll 3+: replacement skipped attempt registers; dedup picks the newer id.
  export GH_MOCK_CHECK_RUNS_JSON
  GH_MOCK_CHECK_RUNS_JSON="$(printf '{"check_runs":[%s,%s]}' "$cancelled" "$replacement")"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
  # The verdict came from a poll that saw the replacement, not from a parse
  # failure degrading into an empty check list.
  assert_no_match 'jq parse failed' "$output"
  [[ "$output" == *"cancelled=1"* ]]
}

@test "regression: cancelled replacement that arrives as success also unblocks" {
  # Same shape as the docs backport storm but the replacement attempt lands
  # on `success` instead of `skipped` (e.g. when the concurrency group fires
  # but the rerun actually executes the job). Dedup must still pick the
  # newer id and the verdict must become green.
  export WAIT_MIN_ATTEMPTS=3
  export WAIT_MAX_ATTEMPTS=5

  cancelled='{"name":"e2e","id":100,"status":"completed","conclusion":"cancelled","started_at":"2026-04-27T07:40:05Z","details_url":"https://external/runs/220/job/1"}'
  replacement='{"name":"e2e","id":200,"status":"completed","conclusion":"success","started_at":"2026-04-27T07:40:15Z","details_url":"https://external/runs/221/job/1"}'

  export GH_MOCK_CHECK_RUNS_SEQ="$MOCK_DIR/cr_seq"
  {
    printf '{"check_runs":[%s]}\n' "$cancelled"
    printf '{"check_runs":[%s]}\n' "$cancelled"
  } > "$GH_MOCK_CHECK_RUNS_SEQ"
  export GH_MOCK_CHECK_RUNS_JSON
  GH_MOCK_CHECK_RUNS_JSON="$(printf '{"check_runs":[%s,%s]}' "$cancelled" "$replacement")"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
  assert_no_match 'jq parse failed' "$output"
  [[ "$output" == *"cancelled=1"* ]]
}

@test "regression: cancelled-only that never gets replaced bails at settle floor (bounded wait)" {
  # A real user-cancelled check that is never replaced must not block the
  # auto-approve job indefinitely. Once the settle floor elapses, treat the
  # cancellation as final and exit non-green. This bounds the wait by
  # min_attempts*sleep_seconds, not max_attempts*sleep_seconds.
  export WAIT_MIN_ATTEMPTS=2
  export WAIT_MAX_ATTEMPTS=10
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"e2e","status":"completed","conclusion":"cancelled","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"e2e"* ]]
  [[ "$output" == *"Cancelled checks are final"* ]]
}

@test "regression: devops-1254 — cancelled behind a running newer suite outlives the settle floor" {
  # vcluster-pro#2155, the v0.34.7 cut. Three pull_request events (opened plus
  # two bot body edits) fired within 23s; concurrency cancelled the first two
  # e2e-next runs. The winning run's `E2E Next Tests` job sits behind an image
  # build, so its check-run did not register until 12:51:41 — while the settle
  # floor expired at 12:49:45 and the pre-fix bail discarded a rerun that was
  # visibly still running. The build job's check-run, in a NEWER check suite
  # than the cancelled attempts, is the evidence that it was still coming.
  export WAIT_MIN_ATTEMPTS=2
  export WAIT_MAX_ATTEMPTS=6

  # One JSON object per PHYSICAL line: the mock reads a sequence entry with
  # `sed -n "${n}p"`, so a pretty-printed fixture is served to the script as a
  # fragment that fails to parse.
  cancelled='{"name":"E2E Next Tests","id":100,"status":"completed","conclusion":"cancelled","started_at":"2026-08-03T12:47:44Z","check_suite":{"id":100},"details_url":"https://github.com/o/r/actions/runs/220/job/1"}'
  building='{"name":"Build vcluster-pro image","id":110,"status":"in_progress","conclusion":null,"started_at":"2026-08-03T12:48:50Z","check_suite":{"id":300},"details_url":"https://github.com/o/r/actions/runs/222/job/1"}'
  built='{"name":"Build vcluster-pro image","id":110,"status":"completed","conclusion":"success","started_at":"2026-08-03T12:48:50Z","check_suite":{"id":300},"details_url":"https://github.com/o/r/actions/runs/222/job/1"}'
  replacement='{"name":"E2E Next Tests","id":200,"status":"completed","conclusion":"success","started_at":"2026-08-03T12:51:43Z","check_suite":{"id":300},"details_url":"https://github.com/o/r/actions/runs/222/job/1"}'

  export GH_MOCK_CHECK_RUNS_SEQ="$MOCK_DIR/cr_seq"
  {
    # Polls 1-3: cancelled attempt from suite 100, and the replacement run's
    # build job (suite 300) still in progress ahead of the cancelled job.
    for _ in 1 2 3; do printf '{"check_runs":[%s,%s]}\n' "$cancelled" "$building"; done
    # Poll 4: the build finished and the replacement E2E check-run registered.
    printf '{"check_runs":[%s,%s,%s]}\n' "$cancelled" "$built" "$replacement"
  } > "$GH_MOCK_CHECK_RUNS_SEQ"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
  # Held past the floor (attempt 2) instead of bailing there.
  [[ "$output" == *"attempt 3/"* ]]
  [[ "$output" == *"cancelled (superseded; newer check suite still running)"* ]]
  assert_no_match 'Cancelled checks are final' "$output"
}

@test "regression: pending check in an OLDER suite does not extend the cancelled hold" {
  # The watermark is directional. A check still running in a suite older than
  # the cancelled attempt is not a replacement for it — nothing newer has been
  # queued — so the floor must still end the wait. Without the comparison this
  # would degrade into "any pending check keeps cancelled alive", which is the
  # unbounded wait the settle floor exists to prevent.
  export WAIT_MIN_ATTEMPTS=2
  export WAIT_MAX_ATTEMPTS=20
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"e2e","status":"completed","conclusion":"cancelled","check_suite":{"id":300},"details_url":"https://github.com/o/r/actions/runs/222/job/1"},
    {"name":"slow-lint","status":"in_progress","conclusion":null,"check_suite":{"id":100},"details_url":"https://github.com/o/r/actions/runs/223/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"Cancelled checks are final"* ]]
  # Bailed at the floor, not at max_attempts.
  assert_no_match 'attempt 3/' "$output"
}

@test "regression: our own in-progress check cannot justify holding a cancelled check" {
  # The self-exclusion is what keeps the new hold bounded: this job's own
  # check-run is always in progress while it polls, and it always lands in the
  # newest check suite. If it counted as "a newer suite is still running", every
  # cancelled check would be held to max_attempts and the settle floor would be
  # dead code.
  export WAIT_MIN_ATTEMPTS=2
  export WAIT_MAX_ATTEMPTS=20
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"e2e","status":"completed","conclusion":"cancelled","check_suite":{"id":100},"details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"auto-approve","status":"in_progress","conclusion":null,"check_suite":{"id":900},"details_url":"https://github.com/o/r/actions/runs/111111/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"Cancelled checks are final"* ]]
  assert_no_match 'attempt 3/' "$output"
}

@test "regression: a skipped rerun must not bury a failure on the same SHA" {
  # Raised in review of vcluster-pro#2156. A workflow that skips its expensive
  # job on a no-op PR-description edit (the DEVOPS-1057 gates) publishes a
  # check-run with the SAME NAME as the job that already failed on this SHA, and
  # a later started_at. Plain latest-wins dedup then picks `skipped`, which
  # counts as green, and a PR whose suite genuinely failed becomes approvable.
  #
  # Not a Checks API artifact: `filter=latest` dedupes within a check suite and
  # each run gets its own suite, so the API returns both attempts. The
  # collapsing was ours.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"E2E Tests","id":100,"status":"completed","conclusion":"failure","started_at":"2026-08-03T13:41:46Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"E2E Tests","id":200,"status":"completed","conclusion":"skipped","started_at":"2026-08-03T13:46:07Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"E2E Tests=failure"* ]]
}

@test "regression: a real re-run that succeeds still clears an earlier failure" {
  # The other half of the ranking, and the reason a failure cannot simply be
  # sticky per name: "Re-run failed jobs" on the same SHA is a normal way to
  # clear a flake on a bump PR. success carries a verdict, so recency decides
  # between it and the failure, and the newer success wins.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"E2E Tests","id":100,"status":"completed","conclusion":"failure","started_at":"2026-08-03T13:41:46Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"E2E Tests","id":200,"status":"completed","conclusion":"success","started_at":"2026-08-03T13:46:07Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "regression: a running rerun outranks an earlier verdict and is waited on" {
  # A pending attempt means the verdict is not in yet, so it must outrank an
  # older success — otherwise we would approve against a stale green while the
  # rerun that supersedes it is still executing. Latest-wins already did this by
  # started_at, so this pins behaviour the ranking must not break rather than
  # behaviour it introduces; it passes against the pre-ranking script too.
  export WAIT_MIN_ATTEMPTS=1
  export WAIT_MAX_ATTEMPTS=2
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"E2E Tests","id":100,"status":"completed","conclusion":"success","started_at":"2026-08-03T13:41:46Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"E2E Tests","id":200,"status":"in_progress","conclusion":null,"started_at":"2026-08-03T13:46:07Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"pending: E2E Tests"* ]]
}

@test "regression: skipped still supersedes cancelled (concurrency replacement)" {
  # The ranking must not undo the replacement fix: skipped and cancelled both
  # carry no verdict, so recency alone decides between them and the newer
  # skipped wins, leaving nothing to block on.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"E2E Istio","id":100,"status":"completed","conclusion":"cancelled","started_at":"2026-08-03T12:47:44Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"E2E Istio","id":200,"status":"completed","conclusion":"skipped","started_at":"2026-08-03T12:51:41Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=true" ]
}

@test "regression: a failure outranks a LATER cancelled attempt" {
  # Ordering is by information content first, so a failure is not displaced by a
  # rerun that was itself cancelled — that rerun produced no verdict, and the
  # failure is still the last thing this SHA actually proved.
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"E2E Tests","id":100,"status":"completed","conclusion":"failure","started_at":"2026-08-03T13:41:46Z","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"E2E Tests","id":200,"status":"completed","conclusion":"cancelled","started_at":"2026-08-03T13:46:07Z","details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"E2E Tests=failure"* ]]
}

@test "regression: cancelled check-runs with no suite id still bail at the floor" {
  # Not every check-run carries a check_suite (external apps, and every fixture
  # written before this watermark existed). A missing id must read as 0 on both
  # sides of the comparison — never as "newer" — so the pre-existing bail
  # behaviour is what an absent suite falls back to.
  export WAIT_MIN_ATTEMPTS=2
  export WAIT_MAX_ATTEMPTS=20
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"e2e","status":"completed","conclusion":"cancelled","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"other","status":"in_progress","conclusion":null,"details_url":"https://github.com/o/r/actions/runs/221/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"Cancelled checks are final"* ]]
  assert_no_match 'attempt 3/' "$output"
}

@test "regression: terminal failure during settle window still bails immediately" {
  # The cancelled-tolerance must NOT extend to terminal conclusions.
  # `failure`/`timed_out`/`action_required` are not replaced by GitHub
  # machinery; they must continue to bail on first detection regardless of
  # the settle floor.
  export WAIT_MIN_ATTEMPTS=20
  export WAIT_MAX_ATTEMPTS=30
  export WAIT_SLEEP_SECONDS=1
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"e2e","status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  # Bailed on attempt 1, not after 20+ polls.
  [[ "$output" != *"attempt 2/"* ]]
}

@test "regression: cancelled + terminal failure mix still bails immediately on the failure" {
  # If a cancelled check coexists with a real failure, the real failure wins
  # and we exit immediately. The cancelled-tolerance does not override
  # terminal failures.
  export WAIT_MIN_ATTEMPTS=10
  export WAIT_MAX_ATTEMPTS=20
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"browser-tests","status":"completed","conclusion":"cancelled","details_url":"https://github.com/o/r/actions/runs/220/job/1"},
    {"name":"e2e","status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv ci_green)" = "ci_green=false" ]
  [[ "$output" == *"e2e"* ]]
  [[ "$output" == *"failure"* ]]
  [[ "$output" != *"attempt 2/"* ]]
}

@test "regression: cancelled does not short-circuit pre-settle empty poll into green" {
  # Belt-and-braces: even if min_attempts=1 and the only signal is cancelled,
  # we never declare ci_green=true. The combination of "cancelled present"
  # and "post-settle" exits non-green, never green.
  export WAIT_MIN_ATTEMPTS=1
  export WAIT_MAX_ATTEMPTS=2
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[
    {"name":"flaky","status":"completed","conclusion":"cancelled","details_url":"https://github.com/o/r/actions/runs/222/job/1"}
  ]}' run "$SCRIPT"
  [ "$status" -eq 0 ]
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

@test "a missing log lib fails loudly instead of logging unsanitized" {
  # An absent lib/log.sh is a packaging fault, and degrading to unsanitized
  # output would silently reopen the check-name channel — the widest one in this
  # script, since whoever posted the check on the head SHA picks `.name`. The
  # script must die rather than emit a verdict. Running a copy with no sibling
  # lib/ reproduces it. This test is what keeps the source-or-die guard honest:
  # weaken it to `|| true`, or move it below the first echo, and this goes red.
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/wait-for-ci.sh"
  GH_MOCK_CHECK_RUNS_JSON='{"check_runs":[]}' run "$BATS_TEST_TMPDIR/wait-for-ci.sh"
  [ "$status" -ne 0 ]
  assert_no_match 'ci_green=true' "$output"
}

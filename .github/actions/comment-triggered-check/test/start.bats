#!/usr/bin/env bats
# API-level tests for start.sh against a stubbed gh.
#
# The rule these pin down: a path that cannot confirm what it needs must refuse
# to open a check-run, rather than fall through and start work on a guess.

load gh_mock

SCRIPT="$BATS_TEST_DIRNAME/../src/start.sh"

setup() {
  setup_gh_mock
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  export INPUT_COMMAND="/test"
  export INPUT_COMMENT_BODY="/test snapshots"
  export INPUT_COMMENT_AUTHOR="dev"
  export INPUT_AUTHOR_ASSOCIATION="MEMBER"
  export INPUT_PR_NUMBER="7"
  export INPUT_REPO="loft-sh/demo"
  export INPUT_CHECK_NAME_PREFIX="e2e"
  export INPUT_RUN_ID="999"
  export INPUT_SERVER_URL="https://github.com"
  export GH_TOKEN="x"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
  teardown_gh_mock
}

kv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-; }
created() { calls_matching "POST"; }

# --- happy path --------------------------------------------------------------

@test "opens a check-run and returns the identity the event does not carry" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv matched)" = "true" ]
  [ "$(kv should-run)" = "true" ]
  [ "$(kv head-sha)" = "abc123" ]
  [ "$(kv base-ref)" = "main" ]
  [ "$(kv check-run-id)" = "4242" ]
  [ "$(kv reason)" = "" ]
}

@test "resolves a release-line base ref, not just the head sha" {
  export GH_MOCK_PR_JSON='{"head":{"sha":"deadbee","ref":"fix/thing","repo":{"full_name":"loft-sh/demo"}},"base":{"ref":"v0.29"},"state":"open"}'
  run bash "$SCRIPT"
  [ "$(kv base-ref)" = "v0.29" ]
  [ "$(kv head-sha)" = "deadbee" ]
}

# GitHub overrides details_url for check-runs owned by the github-actions app,
# so the summary carries the only link back to the logs that survives. Losing it
# leaves a check whose "View details" goes nowhere useful while the suite runs.
@test "the opened check-run links to the run from its summary" {
  run bash "$SCRIPT"
  [ "$(calls_matching 'View the run.*actions/runs/999')" -ge 1 ]
}

@test "no run id means no link rather than a broken one" {
  export INPUT_RUN_ID=""
  run bash "$SCRIPT"
  [ "$(calls_matching 'View the run')" -eq 0 ]
  [ "$(kv check-run-id)" = "4242" ]
}

# A caller that hands the work to a non-privileged run dispatches by branch, and
# `gh workflow run --ref` will not take a SHA.
@test "resolves the head branch as well as the head sha" {
  export GH_MOCK_PR_JSON='{"head":{"sha":"deadbee","ref":"fix/thing","repo":{"full_name":"loft-sh/demo"}},"base":{"ref":"v0.29"},"state":"open"}'
  run bash "$SCRIPT"
  [ "$(kv head-ref)" = "fix/thing" ]
}

@test "a payload with no head ref is treated as unreadable" {
  export GH_MOCK_PR_JSON='{"head":{"sha":"abc123","repo":{"full_name":"loft-sh/demo"}},"base":{"ref":"main"},"state":"open"}'
  run bash "$SCRIPT"
  [ "$(kv reason)" = "pull-request-unreadable" ]
  [ "$(created)" -eq 0 ]
}

@test "the whole happy path costs exactly two API calls" {
  run bash "$SCRIPT"
  [ "$(call_count)" -eq 2 ]
}

@test "emits a concurrency key the caller can interpolate safely" {
  export INPUT_COMMENT_BODY='/test containsAny {aws, azure}'
  run bash "$SCRIPT"
  key="$(kv concurrency-key)"
  [[ "$key" =~ ^containsany-aws-azure-[0-9a-f]{8}$ ]]
}

@test "the emitted key distinguishes filters the slug alone would merge" {
  export INPUT_COMMENT_BODY='/test snapshots && aws'
  run bash "$SCRIPT"
  first="$(kv concurrency-key)"

  : > "$GITHUB_OUTPUT"
  export INPUT_COMMENT_BODY='/test snapshots || aws'
  run bash "$SCRIPT"
  [ "$first" != "$(kv concurrency-key)" ]
}

# --- authorization -----------------------------------------------------------

@test "a past contributor cannot run it, and no API call is made" {
  export INPUT_AUTHOR_ASSOCIATION="CONTRIBUTOR"
  run bash "$SCRIPT"
  [ "$(kv reason)" = "insufficient-permission" ]
  [ "$(kv should-run)" = "false" ]
  [ "$(call_count)" -eq 0 ]
}

@test "a missing association is refused rather than defaulted to allowed" {
  export INPUT_AUTHOR_ASSOCIATION=""
  run bash "$SCRIPT"
  [ "$(kv reason)" = "insufficient-permission" ]
  [ "$(call_count)" -eq 0 ]
}

@test "a fork pull request is refused and nothing is created" {
  export GH_MOCK_PR_JSON='{"head":{"sha":"abc123","ref":"feature/x","repo":{"full_name":"someone/demo"}},"base":{"ref":"main"},"state":"open"}'
  run bash "$SCRIPT"
  [ "$(kv reason)" = "fork" ]
  [ "$(kv should-run)" = "false" ]
  [ "$(created)" -eq 0 ]
}

@test "a closed pull request is refused" {
  export GH_MOCK_PR_JSON='{"head":{"sha":"abc123","ref":"feature/x","repo":{"full_name":"loft-sh/demo"}},"base":{"ref":"main"},"state":"closed"}'
  run bash "$SCRIPT"
  [ "$(kv reason)" = "pull-request-closed" ]
  [ "$(created)" -eq 0 ]
}

# --- API failures must not fall through -------------------------------------

@test "an unreadable pull request stops rather than guessing" {
  export GH_MOCK_PR_FAIL=1
  run bash "$SCRIPT"
  [ "$(kv reason)" = "pull-request-unreadable" ]
  [ "$(created)" -eq 0 ]
}

@test "a pull request payload missing the base ref is treated as unreadable" {
  export GH_MOCK_PR_JSON='{"head":{"sha":"abc123","ref":"feature/x","repo":{"full_name":"loft-sh/demo"}},"state":"open"}'
  run bash "$SCRIPT"
  [ "$(kv reason)" = "pull-request-unreadable" ]
  [ "$(created)" -eq 0 ]
}

@test "a failed create is reported, not returned as success" {
  export GH_MOCK_CREATE_FAIL=1
  run bash "$SCRIPT"
  [ "$(kv reason)" = "check-run-not-created" ]
  [ "$(kv check-run-id)" = "" ]
  [ "$(kv should-run)" = "false" ]
}

# --- quiet paths -------------------------------------------------------------

@test "an ordinary comment touches no API at all" {
  export INPUT_COMMENT_BODY="LGTM"
  run bash "$SCRIPT"
  [ "$(kv matched)" = "false" ]
  [ "$(call_count)" -eq 0 ]
}

@test "an empty filter is reported before any API call" {
  export INPUT_COMMENT_BODY="/test"
  run bash "$SCRIPT"
  [ "$(kv reason)" = "empty-filter" ]
  [ "$(call_count)" -eq 0 ]
}

@test "a comment outside a pull request is reported before any API call" {
  export INPUT_PR_NUMBER=""
  run bash "$SCRIPT"
  [ "$(kv reason)" = "not-a-pull-request" ]
  [ "$(call_count)" -eq 0 ]
}

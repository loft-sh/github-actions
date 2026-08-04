#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/check-pr-ready.sh"
load gh_mock
load assertions

setup() {
  setup_gh_mock
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_REPOSITORY="owner/repo"
  export PR_NUMBER=42
  export PR_AUTHOR="dependabot[bot]"
  # Keep retry budget bounded so tests don't stall the suite.
  export MERGEABLE_MAX_ATTEMPTS=2
  export MERGEABLE_SLEEP_SECONDS=0
}
teardown() { rm -f "$GITHUB_OUTPUT"; teardown_gh_mock; }

kv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1; }

@test "mergeable=true + different approver → proceed=true" {
  GH_MOCK_MERGEABLE=true GH_MOCK_APPROVER="loft-bot" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
}

@test "mergeable=false → proceed=false, reported as a conflict needing a rebase" {
  GH_MOCK_MERGEABLE=false GH_MOCK_APPROVER="loft-bot" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"::warning::PR #42 has merge conflicts"* ]]
}

@test "regression: mergeable=false is definitive and must not burn the retry budget" {
  # jq's `//` used to collapse false into "null", so a conflicted PR looked
  # like un-computed metadata and re-polled until the budget ran out.
  # MERGEABLE_MAX_ATTEMPTS=2 here, so a second poll would prove the regression.
  GH_MOCK_MERGEABLE=false GH_MOCK_APPROVER="loft-bot" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'pulls/42' "$GH_MOCK_CALLS")" -eq 1 ]
}

@test "mergeable=null → proceed=false (never treat unknown as clean)" {
  GH_MOCK_MERGEABLE=null GH_MOCK_APPROVER="loft-bot" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  # Distinct from the conflict case above: transient, so a re-run is advised
  # rather than a rebase.
  [[ "$output" == *"did not report mergeability"* ]]
  [[ "$output" == *"transient"* ]]
  [[ "$output" != *"merge conflicts"* ]]
}

@test "approver == author → proceed=false (self-review guard)" {
  GH_MOCK_MERGEABLE=true GH_MOCK_APPROVER="dependabot[bot]" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"::error::the approving identity"* ]]
  [[ "$output" == *"self-approval"* ]]
}

@test "empty approver → proceed=false, reported as a token problem not self-approval" {
  GH_MOCK_MERGEABLE=true GH_MOCK_APPROVER="" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"::error::could not resolve the authenticated user"* ]]
  [[ "$output" != *"self-approval"* ]]
}

@test "regression: a CR in the authenticated login cannot forge a workflow command" {
  # "GitHub logins cannot contain control characters" does not close this
  # channel: the API answers in JSON, and a \r escape inside a JSON string
  # decodes to a real CR through `jq -r`. GH_MOCK_APPROVER carries the escape
  # (literal backslash-r) exactly as a real API response would.
  #
  # PR_AUTHOR must equal the decoded login to reach the self-approval line, so
  # it holds the real CR.
  GH_MOCK_MERGEABLE=true \
    GH_MOCK_APPROVER='dependabot[bot]\r::error::FORGED' \
    PR_AUTHOR=$'dependabot[bot]\r::error::FORGED' \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  # No CR anywhere: grep splits on LF only, so a line-anchored assertion alone
  # would pass with the bug live.
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
  # The identity is still reported, flattened onto the one annotation line.
  [[ "$output" == *"the approving identity"* ]]
  [[ "$output" == *"dependabot[bot]"* ]]
}

@test "missing PR_NUMBER fails" {
  run env -u PR_NUMBER GITHUB_OUTPUT="$GITHUB_OUTPUT" GITHUB_REPOSITORY=o/r PR_AUTHOR=x "$SCRIPT"
  [ "$status" -ne 0 ]
}

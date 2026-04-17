#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/check-pr-ready.sh"
load gh_mock

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

@test "mergeable=false → proceed=false" {
  GH_MOCK_MERGEABLE=false GH_MOCK_APPROVER="loft-bot" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
}

@test "mergeable=null → proceed=false (never treat unknown as clean)" {
  GH_MOCK_MERGEABLE=null GH_MOCK_APPROVER="loft-bot" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
}

@test "approver == author → proceed=false (self-review guard)" {
  GH_MOCK_MERGEABLE=true GH_MOCK_APPROVER="dependabot[bot]" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
}

@test "empty approver → proceed=false" {
  GH_MOCK_MERGEABLE=true GH_MOCK_APPROVER="" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
}

@test "missing PR_NUMBER fails" {
  run env -u PR_NUMBER GITHUB_OUTPUT="$GITHUB_OUTPUT" GITHUB_REPOSITORY=o/r PR_AUTHOR=x "$SCRIPT"
  [ "$status" -ne 0 ]
}

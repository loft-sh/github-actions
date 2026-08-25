#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/check-pr-after-ci.sh"
load gh_mock

setup() {
  setup_gh_mock
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_REPOSITORY="owner/repo"
  export PR_NUMBER=42
  export EXPECTED_HEAD_SHA="tested-head-sha"
  export GH_MOCK_HEAD_SHA="tested-head-sha"
}
teardown() { rm -f "$GITHUB_OUTPUT"; teardown_gh_mock; }

kv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1; }

@test "same mergeable head proceeds" {
  GH_MOCK_MERGEABLE=true run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
}

@test "unresolved mergeability does not discard a tested head" {
  GH_MOCK_MERGEABLE=null run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
}

@test "definitive merge conflict blocks approval" {
  GH_MOCK_MERGEABLE=false run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"merge conflicts"* ]]
}

@test "moved mergeable head blocks approval" {
  GH_MOCK_MERGEABLE=true GH_MOCK_HEAD_SHA="new-head-sha" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"head changed"* ]]
}

@test "head mismatch takes precedence over a conflict" {
  GH_MOCK_MERGEABLE=false GH_MOCK_HEAD_SHA="new-head-sha" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"head changed"* ]]
  [[ "$output" != *"merge conflicts"* ]]
}

@test "unreadable PR state fails closed" {
  GH_MOCK_PULL_FAIL=always run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"could not read PR #42"* ]]
}

@test "missing EXPECTED_HEAD_SHA fails" {
  run env -u EXPECTED_HEAD_SHA GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    GITHUB_REPOSITORY=o/r PR_NUMBER=1 "$SCRIPT"
  [ "$status" -ne 0 ]
}

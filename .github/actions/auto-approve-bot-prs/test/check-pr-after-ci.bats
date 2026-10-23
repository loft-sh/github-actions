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
  export MERGEABLE_MAX_ATTEMPTS=3
  export MERGEABLE_SLEEP_SECONDS=0
}
teardown() { rm -f "$GITHUB_OUTPUT"; teardown_gh_mock; }

kv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1; }

@test "same mergeable head proceeds" {
  GH_MOCK_MERGEABLE=true run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
}

@test "unresolved mergeability does not discard a tested head after a bounded wait" {
  GH_MOCK_MERGEABLE=null run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
  [ "$(grep -c 'pulls/42' "$GH_MOCK_CALLS")" -eq 3 ]
  [[ "$output" == *"::notice::GitHub did not report mergeability for PR #42 within 3 attempts after CI"* ]]
}

@test "waits for GitHub to compute mergeability after CI" {
  printf 'null\ntrue\n' > "$BATS_TEST_TMPDIR/pulls"
  GH_MOCK_PULL_SEQ="$BATS_TEST_TMPDIR/pulls" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
  [ "$(grep -c 'pulls/42' "$GH_MOCK_CALLS")" -eq 2 ]
  [[ "$output" != *"::notice::"* ]]
}

@test "a conflict computed during the wait blocks approval" {
  printf 'null\nnull\nfalse\n' > "$BATS_TEST_TMPDIR/pulls"
  GH_MOCK_PULL_SEQ="$BATS_TEST_TMPDIR/pulls" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"merge conflicts"* ]]
}

@test "a transient read failure after CI is retried" {
  printf 'ERROR\ntrue\n' > "$BATS_TEST_TMPDIR/pulls"
  GH_MOCK_PULL_SEQ="$BATS_TEST_TMPDIR/pulls" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
  [ "$(grep -c 'pulls/42' "$GH_MOCK_CALLS")" -eq 2 ]
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
  [[ "$output" == *"could not read PR #42 after CI within 3 attempts"* ]]
  [ "$(grep -c 'pulls/42' "$GH_MOCK_CALLS")" -eq 3 ]
}

@test "missing EXPECTED_HEAD_SHA fails" {
  run env -u EXPECTED_HEAD_SHA GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    GITHUB_REPOSITORY=o/r PR_NUMBER=1 "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "a skip label keeps the PR for a person" {
  GH_MOCK_MERGEABLE=true GH_MOCK_LABELS='["backport-ai-resolved"]' SKIP_LABELS="backport-ai-resolved" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"::notice::PR #42 is labeled 'backport-ai-resolved'"* ]]
}

@test "any label from a list with spaces matches" {
  GH_MOCK_MERGEABLE=true GH_MOCK_LABELS='["Large","hold"]' SKIP_LABELS=" backport-ai-resolved , hold " run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"labeled 'hold'"* ]]
}

@test "other labels do not block approval" {
  GH_MOCK_MERGEABLE=true GH_MOCK_LABELS='["Large"]' SKIP_LABELS="backport-ai-resolved" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
}

@test "without skip-labels a labeled PR proceeds as before" {
  GH_MOCK_MERGEABLE=true GH_MOCK_LABELS='["backport-ai-resolved"]' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
}

@test "a moved head is reported before a skip label" {
  GH_MOCK_MERGEABLE=true GH_MOCK_HEAD_SHA="new-head-sha" GH_MOCK_LABELS='["backport-ai-resolved"]' SKIP_LABELS="backport-ai-resolved" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" == *"head changed"* ]]
}

@test "a skip label read while mergeability is pending still blocks" {
  printf 'null\ntrue\n' > "$BATS_TEST_TMPDIR/pulls"
  GH_MOCK_PULL_SEQ="$BATS_TEST_TMPDIR/pulls" GH_MOCK_LABELS='["backport-ai-resolved"]' SKIP_LABELS="backport-ai-resolved" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  # Decided on the first read, before mergeability resolves.
  [ "$(grep -c 'pulls/42' "$GH_MOCK_CALLS")" -eq 1 ]
}

@test "a skip label blocks even when mergeability never resolves" {
  GH_MOCK_MERGEABLE=null GH_MOCK_LABELS='["backport-ai-resolved"]' SKIP_LABELS="backport-ai-resolved" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
  [[ "$output" != *"did not report mergeability"* ]]
}

@test "skip labels match without case, as GitHub labels do" {
  GH_MOCK_MERGEABLE=true GH_MOCK_LABELS='["backport-ai-resolved"]' SKIP_LABELS="Backport-AI-Resolved" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=false" ]
}

@test "labels with quotes or backslashes do not break the read" {
  GH_MOCK_MERGEABLE=true GH_MOCK_LABELS='["say \"hi\"", "a\\b"]' SKIP_LABELS="backport-ai-resolved" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv proceed)" = "proceed=true" ]
  GH_MOCK_MERGEABLE=true GH_MOCK_LABELS='["say \"hi\"", "backport-ai-resolved"]' SKIP_LABELS="backport-ai-resolved" run "$SCRIPT"
  [ "$(kv proceed)" = "proceed=false" ]
}

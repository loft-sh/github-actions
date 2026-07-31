#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/enable-auto-merge.sh"
load gh_mock

setup() {
  setup_gh_mock
  export GITHUB_REPOSITORY="owner/repo"
  export PR_NUMBER=42
  export MERGE_METHOD="squash"
}
teardown() { teardown_gh_mock; }

# Did `gh pr merge` get called with --auto at least once?
auto_merge_attempted() { grep -q '^pr merge .*--auto' "$GH_MOCK_CALLS"; }
# ...and without it (the plain merge)?
plain_merge_attempted() { grep '^pr merge ' "$GH_MOCK_CALLS" | grep -qv -- '--auto'; }

@test "plain merge succeeds → merged without touching auto-merge" {
  GH_MOCK_PR_MERGE_EXIT=0 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Merged PR #42 (squash)"* ]]
  plain_merge_attempted
  ! auto_merge_attempted
  # The whole point of preferring the plain merge: no dependency on the
  # repository's allow_auto_merge setting on the happy path.
  [[ "$output" != *"::error::"* ]]
  [[ "$output" != *"::warning::"* ]]
}

@test "plain merge refused on an open PR → falls back to --auto and warns" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=0 GH_MOCK_PR_STATE=OPEN run "$SCRIPT"
  [ "$status" -eq 0 ]
  plain_merge_attempted
  auto_merge_attempted
  [[ "$output" == *"::warning::PR #42 could not be merged immediately"* ]]
  [[ "$output" != *"::error::"* ]]
}

@test "both merge paths refused → ::error:: naming both reasons, still exits 0" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_PR_MERGE_OUT="plain boom" GH_MOCK_PR_MERGE_AUTO_OUT="auto boom" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::PR #42 was approved but could NOT be merged"* ]]
  # Both diagnostics are carried into the annotation, since this is the only
  # place the cause is knowable.
  [[ "$output" == *"plain boom"* ]]
  [[ "$output" == *"auto boom"* ]]
}

@test "already merged → benign, no auto-merge attempt, no error" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=MERGED run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already merged"* ]]
  ! auto_merge_attempted
  [[ "$output" != *"::error::"* ]]
}

@test "closed unmerged → warning, no auto-merge attempt, no error" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=CLOSED run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::PR #42 is closed without being merged"* ]]
  ! auto_merge_attempted
  [[ "$output" != *"::error::"* ]]
}

@test "unreadable PR state does not mask a failed merge" {
  # `gh pr view` failing must not be read as "already merged" — the run still
  # has to try --auto and, failing that, escalate.
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=1 GH_MOCK_PR_STATE="" run "$SCRIPT"
  [ "$status" -eq 0 ]
  auto_merge_attempted
  [[ "$output" == *"::error::"* ]]
}

@test "invalid merge method → ::error::, no merge attempted" {
  MERGE_METHOD="fast-forward" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::Invalid merge method 'fast-forward'"* ]]
  ! plain_merge_attempted
  ! auto_merge_attempted
}

@test "each valid merge method is passed through to gh" {
  for m in squash merge rebase; do
    : > "$GH_MOCK_CALLS"
    MERGE_METHOD="$m" GH_MOCK_PR_MERGE_EXIT=0 run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- "--${m}" "$GH_MOCK_CALLS"
  done
}

@test "missing PR_NUMBER fails" {
  run env -u PR_NUMBER GITHUB_REPOSITORY=o/r MERGE_METHOD=squash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing MERGE_METHOD fails" {
  run env -u MERGE_METHOD GITHUB_REPOSITORY=o/r PR_NUMBER=1 "$SCRIPT"
  [ "$status" -ne 0 ]
}

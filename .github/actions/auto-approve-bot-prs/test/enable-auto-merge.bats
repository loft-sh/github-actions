#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/enable-auto-merge.sh"
load gh_mock
load assertions

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

# ---------------------------------------------------------------------------
# Log-injection. gh's output is GitHub-controlled and merge-method is the
# calling workflow's, and all three reach a workflow-command line here. CR
# terminates a log line for the runner, so a raw one starts a NEW line and a
# line beginning '::' is parsed as a command.
#
# Note every guard below asserts there is no CR in the output *at all*. A
# line-anchored grep cannot fail on a CR-delimited payload, because grep splits
# on LF only while the runner also splits on CR — so an unsanitized payload
# would satisfy a '^::error::' check and the test would pass with the bug live.

@test "regression: a CR in the plain-merge error cannot forge a workflow command" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=0 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_PR_MERGE_OUT=$'refused\r::error::FORGED\r100% done' run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
  # Still reported, flattened onto the one notice line.
  [[ "$output" == *"refused"* ]]
  # '%' is escaped so the runner cannot decode %0A/%25 out of gh's text.
  [[ "$output" == *"100%25 done"* ]]
}

@test "regression: a CR in the auto-merge error cannot forge a workflow command" {
  # The second channel, reached only on the both-paths-refused route, which is
  # also the one that emits ::error::.
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_PR_MERGE_OUT="plain boom" \
    GH_MOCK_PR_MERGE_AUTO_OUT=$'auto boom\r::error::FORGED' run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
  [[ "$output" == *"was approved but could NOT be merged"* ]]
  [[ "$output" == *"auto boom"* ]]
}

@test "regression: a CR in merge-method cannot forge a workflow command" {
  # Caller-controlled rather than API-controlled: merge-method is a plain
  # workflow_call string input, echoed back on rejection.
  MERGE_METHOD=$'fast-forward\r::error::FORGED' run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
  [[ "$output" == *"Invalid merge method"* ]]
  # The rejected value is still shown, so the operator can see the typo.
  [[ "$output" == *"fast-forward"* ]]
}

@test "a missing log lib fails loudly instead of logging unsanitized" {
  # The one place this action prefers a hard failure: an absent lib/log.sh is a
  # packaging fault, and degrading to unsanitized output would silently reopen
  # every channel above. Running a copy with no sibling lib/ reproduces it.
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/enable-auto-merge.sh"
  GH_MOCK_PR_MERGE_EXIT=0 run "$BATS_TEST_TMPDIR/enable-auto-merge.sh"
  [ "$status" -ne 0 ]
  assert_no_match 'Merged PR' "$output"
}

@test "regression: a very long gh error is truncated with a marker, not severed" {
  long=$(printf 'x%.0s' $(seq 1 900))
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_PR_MERGE_OUT="$long" GH_MOCK_PR_MERGE_AUTO_OUT="$long" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"... (truncated)"* ]]
  # Bounded: the 900-char payload cannot reach the annotation whole.
  assert_no_match "x{600}" "$output"
}

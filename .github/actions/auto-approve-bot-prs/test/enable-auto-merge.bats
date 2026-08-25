#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/enable-auto-merge.sh"
load gh_mock
load assertions

setup() {
  setup_gh_mock
  export GITHUB_REPOSITORY="owner/repo"
  export PR_NUMBER=42
  export MERGE_METHOD="squash"
  export PR_HEAD_SHA="tested-head-sha"
  # Every refusal path retries once. Keep the backoff out of the suite runtime —
  # at the 5s default the failure-path tests alone add over a minute.
  export MERGE_RETRY_SLEEP_SECONDS=0
}
teardown() { teardown_gh_mock; }

# Did `gh pr merge` get called with --auto at least once?
auto_merge_attempted() { grep -q '^pr merge .*--auto' "$GH_MOCK_CALLS"; }
# ...and without it (the plain merge)?
plain_merge_attempted() { grep '^pr merge ' "$GH_MOCK_CALLS" | grep -qv -- '--auto'; }

# Negative forms route through assert_no_match rather than negating the two
# helpers above with `!`. Bash exempts a `!`-inverted command from `set -e`, so
# `! auto_merge_attempted` is inert unless it happens to be the last line of the
# test body — which silently unproved the "no auto-merge attempt" half of four
# titles below. See assertions.bash.
assert_no_auto_merge() { assert_no_match '^pr merge .*--auto' "$(cat "$GH_MOCK_CALLS")"; }
assert_no_merge_at_all() { assert_no_match '^pr merge ' "$(cat "$GH_MOCK_CALLS")"; }

@test "plain merge succeeds → merged without touching auto-merge" {
  GH_MOCK_PR_MERGE_EXIT=0 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Merged PR #42 (squash)"* ]]
  plain_merge_attempted
  assert_no_auto_merge
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
  assert_no_auto_merge
  [[ "$output" != *"::error::"* ]]
}

@test "closed unmerged → warning, no auto-merge attempt, no error" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=CLOSED run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::PR #42 is closed without being merged"* ]]
  assert_no_auto_merge
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
  # One assertion covers both: the rejected-method path must issue no
  # `gh pr merge` at all, neither plain nor --auto.
  assert_no_merge_at_all
}

# ---------------------------------------------------------------------------
# Retry. One bounded retry per merge call, so a single transient blip is not
# escalated as though it were a permanent policy refusal.

# How many times was `gh pr merge` called, with and without --auto? Mirrors the
# shape of plain_merge_attempted: the mock records the whole arg line, so --auto
# has to be excluded by match, not by position.
plain_merge_count() { grep '^pr merge ' "$GH_MOCK_CALLS" | grep -cv -- '--auto' || true; }
auto_merge_count() { grep -c '^pr merge .*--auto' "$GH_MOCK_CALLS" || true; }

@test "a successful plain merge is not retried" {
  GH_MOCK_PR_MERGE_EXIT=0 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(plain_merge_count)" -eq 1 ]
}

@test "a refused plain merge is retried once before falling back" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=0 GH_MOCK_PR_STATE=OPEN run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Twice, not once: the retry has to actually issue a second call.
  [ "$(plain_merge_count)" -eq 2 ]
}

@test "a refused --auto is retried once before escalating" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=1 GH_MOCK_PR_STATE=OPEN run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(auto_merge_count)" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
  # The escalation says it retried, so the reader knows a transient cause was
  # already ruled out once.
  [[ "$output" == *"retried once"* ]]
}

@test "the queued warning does not promise the merge will complete on its own" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=0 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_PR_MERGE_OUT="not up to date with base" run "$SCRIPT"
  [ "$status" -eq 0 ]
  # A queue accepted is not a merge landed: an up-to-date rule with no
  # auto-update, a mid-wait conflict, or allow_auto_merge being off all sit here
  # forever. The warning must point at what to check, and carry the refusal.
  [[ "$output" == *"queued via GitHub auto-merge"* ]]
  [[ "$output" == *"auto-merge is enabled on the repository"* ]]
  [[ "$output" == *"up to date with its base"* ]]
  [[ "$output" == *"not up to date with base"* ]]
  assert_no_match 'will land once the remaining requirements pass' "$output"
}

# ---------------------------------------------------------------------------
# merge-when-blocked: retry a client-side refusal through the API, so a merge
# token's ruleset bypass gets a chance to apply.

api_merge_attempted() { grep -q '^api .*/pulls/42/merge' "$GH_MOCK_CALLS"; }
assert_no_api_merge() { assert_no_match '^api .*/pulls/42/merge' "$(cat "$GH_MOCK_CALLS")"; }
api_merge_count() { grep -c '^api .*/pulls/42/merge' "$GH_MOCK_CALLS" || true; }

@test "merge-when-blocked off → a refused plain merge never reaches the merge API" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=0 GH_MOCK_PR_STATE=OPEN run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_api_merge
  auto_merge_attempted
}

@test "merge-when-blocked on → refused plain merge is retried through the API and lands" {
  MERGE_WHEN_BLOCKED=true GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_API_MERGE_EXIT=0 run "$SCRIPT"
  [ "$status" -eq 0 ]
  api_merge_attempted
  [[ "$output" == *"through the merge API"* ]]
  assert_no_auto_merge
  [[ "$output" != *"::error::"* ]]
  [[ "$output" != *"::warning::"* ]]
}

@test "merge-when-blocked on but the API refuses too → falls back to --auto as before" {
  MERGE_WHEN_BLOCKED=true GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_API_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=0 run "$SCRIPT"
  [ "$status" -eq 0 ]
  api_merge_attempted
  auto_merge_attempted
  [[ "$output" == *"::warning::PR #42 could not be merged immediately"* ]]
}

@test "a token with no bypass is refused by the API, and the error says so" {
  MERGE_WHEN_BLOCKED=true GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_API_MERGE_EXIT=1 GH_MOCK_API_MERGE_OUT="At least 1 approving review is required" \
    GH_MOCK_PR_MERGE_AUTO_EXIT=1 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"Merge API said:"* ]]
  [[ "$output" == *"At least 1 approving review is required"* ]]
}

@test "with merge-when-blocked off the error names the setting rather than hiding it" {
  # Otherwise the annotation blames branch protection for gh declining to ask.
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=1 GH_MOCK_PR_STATE=OPEN run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"merge-when-blocked is off"* ]]
  assert_no_match 'Merge API said:' "$output"
}

@test "the API merge is guarded by the tested head SHA" {
  MERGE_WHEN_BLOCKED=true GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_API_MERGE_EXIT=0 run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- 'sha=tested-head-sha' "$GH_MOCK_CALLS"
  grep -q -- 'merge_method=squash' "$GH_MOCK_CALLS"
}

@test "a refused API merge is retried once, like the other two paths" {
  MERGE_WHEN_BLOCKED=true GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_API_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=0 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(api_merge_count)" -eq 2 ]
}

@test "an already-merged PR short-circuits before the API merge" {
  # Re-runs are routine; a 405 here would read like a real failure.
  MERGE_WHEN_BLOCKED=true GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=MERGED run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already merged"* ]]
  assert_no_api_merge
}

@test "regression: a CR in the merge-API error cannot forge a workflow command" {
  MERGE_WHEN_BLOCKED=true GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_STATE=OPEN \
    GH_MOCK_API_MERGE_EXIT=1 GH_MOCK_API_MERGE_OUT=$'api boom\r::error::FORGED' \
    GH_MOCK_PR_MERGE_AUTO_EXIT=1 run "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
  [[ "$output" == *"api boom"* ]]
}

@test "each valid merge method is passed through to gh" {
  for m in squash merge rebase; do
    : > "$GH_MOCK_CALLS"
    MERGE_METHOD="$m" GH_MOCK_PR_MERGE_EXIT=0 run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- "--${m}" "$GH_MOCK_CALLS"
  done
}

@test "every direct and queued merge attempt requires the tested head SHA" {
  GH_MOCK_PR_MERGE_EXIT=1 GH_MOCK_PR_MERGE_AUTO_EXIT=0 GH_MOCK_PR_STATE=OPEN run "$SCRIPT"
  [ "$status" -eq 0 ]
  merge_calls="$(grep '^pr merge ' "$GH_MOCK_CALLS")"
  merge_call_count="$(printf '%s\n' "$merge_calls" | grep -c '^pr merge ')"
  guarded_call_count="$(printf '%s\n' "$merge_calls" | grep -c -- '--match-head-commit tested-head-sha')"
  [ "$guarded_call_count" -eq "$merge_call_count" ]
}

@test "missing PR_NUMBER fails" {
  run env -u PR_NUMBER GITHUB_REPOSITORY=o/r MERGE_METHOD=squash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing MERGE_METHOD fails" {
  run env -u MERGE_METHOD GITHUB_REPOSITORY=o/r PR_NUMBER=1 "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing PR_HEAD_SHA fails" {
  run env -u PR_HEAD_SHA GITHUB_REPOSITORY=o/r PR_NUMBER=1 MERGE_METHOD=squash "$SCRIPT"
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

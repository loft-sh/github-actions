#!/usr/bin/env bats
# The reply comment: pure rendering, and link mode against a stubbed gh.

load gh_mock

LIB="$BATS_TEST_DIRNAME/../src/lib.sh"
LINK="$BATS_TEST_DIRNAME/../src/link.sh"
BASE="https://github.com/loft-sh/demo"

setup() {
  # shellcheck source=../src/lib.sh
  source "$LIB"
  setup_gh_mock
  export INPUT_REPO="loft-sh/demo"
  export INPUT_SERVER_URL="https://github.com"
  export INPUT_REPLY_JITTER_SECONDS="0"
  export GH_TOKEN="x"
}

teardown() {
  teardown_gh_mock
}

state() {
  jq -c -n --arg cmd "${1:-/test-e2e snapshots}" --argjson runs "${2:-[]}" \
    '{v: 1, comment_id: 777, command: $cmd, attempt: 1, runs: $runs}'
}
# check <id> <status> [conclusion] [run-url] — a check-run as the API returns it,
# carrying reply 555 and, once linked, its run.
check() {
  jq -c -n --argjson id "$1" --arg s "$2" --arg c "${3-}" --arg u "${4-}" \
    '{id: $id, status: $s, conclusion: (if $c == "" then null else $c end), head_sha: "abc1234def56",
      app: {slug: "github-actions"}, external_id: ("555" + (if $u == "" then "" else " " + $u end))}'
}
seed_check() { check "$@" > "$MOCK_DIR/checkrun-$1.json"; }
seed_reply() { # id state
  render_reply "$2" '[]' "https://github.com" "loft-sh/demo" > "$MOCK_DIR/comment-$1"
}
body_of() { cat "$MOCK_DIR/comment-$1"; }
TWO='[{"id":11,"label":"Pro"},{"id":12,"label":"OSS"}]'

# --- rendering ---------------------------------------------------------------

@test "a running run with a link says running and links the run" {
  run render_reply "$(state "" '[{"id":11,"label":"Pro"}]')" \
    "[$(check 11 in_progress "" https://example.com/run/1)]" https://github.com loft-sh/demo
  [[ "$output" == *':rocket: `/test-e2e snapshots` started 1 run on `abc1234`. This comment updates when it finishes.'* ]]
  [[ "$output" == *"- Pro: running, [watch the run](https://example.com/run/1)"* ]]
}

@test "a run with no link yet points at its check" {
  run render_reply "$(state "" "$TWO")" "[$(check 11 in_progress),$(check 12 queued)]" https://github.com loft-sh/demo
  [[ "$output" == *"started 2 runs"*"when they finish."* ]]
  [[ "$output" == *"- OSS: starting, [view the check](${BASE}/runs/12)"* ]]
}

@test "finished runs show their outcome and a check mark when none failed" {
  run render_reply "$(state "" "$TWO")" \
    "[$(check 11 completed success https://e/1),$(check 12 completed neutral https://e/2)]" https://github.com loft-sh/demo
  [[ "$output" == *':white_check_mark: `/test-e2e snapshots` finished on `abc1234`.'* ]]
  [[ "$output" == *"- Pro: passed, [view the run](https://e/1)"* ]]
  [[ "$output" == *"- OSS: nothing to run, [view the run](https://e/2)"* ]]
}

@test "any failed, timed out or cancelled run gives a cross" {
  for pair in failure:failed timed_out:"timed out" cancelled:cancelled; do
    c="${pair%%:*}" phrase="${pair#*:}"
    run render_reply "$(state "" "$TWO")" \
      "[$(check 11 completed success https://e/1),$(check 12 completed "$c" https://e/2)]" https://github.com loft-sh/demo
    [[ "$output" == *":x: "*"finished"* ]]
    [[ "$output" == *"- OSS: ${phrase//\"/}, [view the run](https://e/2)"* ]]
  done
}

@test "the headline waits for the last run" {
  run render_reply "$(state "" "$TWO")" \
    "[$(check 11 completed failure https://e/1),$(check 12 in_progress "" https://e/2)]" https://github.com loft-sh/demo
  [[ "$output" == *":rocket: "* ]]
  [[ "$output" == *"- Pro: failed,"* ]]
}

@test "a failed check that never got a run did not start" {
  run render_reply "$(state "" '[{"id":13,"label":"Platform, run 3 of 3"}]')" \
    "[$(check 13 completed failure)]" https://github.com loft-sh/demo
  [[ "$output" == *"- Platform, run 3 of 3: did not start, [see why](${BASE}/runs/13)"* ]]
}

@test "a check that could not be read renders as unknown instead of failing" {
  run render_reply "$(state "" '[{"id":11,"label":"Pro"}]')" '[]' https://github.com loft-sh/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"- Pro: status unknown, [view the check](${BASE}/runs/11)"* ]]
}

@test "a reply with no runs says nothing started" {
  run render_reply "$(state)" '[]' https://github.com loft-sh/demo
  [[ "$output" == *':x: `/test-e2e snapshots` could not start any run.'* ]]
}

@test "a backtick in the command cannot break out of the code span" {
  run render_reply "$(state '/test-e2e a`b')" '[]' https://github.com loft-sh/demo
  [[ "$output" == *'`` /test-e2e a`b ``'* ]]
}

@test "a run of backticks gets a longer fence, so text after it stays code" {
  run render_reply "$(state '/test-e2e a``b @someone')" '[]' https://github.com loft-sh/demo
  [[ "$output" == *'``` /test-e2e a``b @someone ```'* ]]
}

@test "a long command is shortened" {
  long="/test-e2e $(printf 'x%.0s' {1..300})"
  run render_reply "$(state "$long")" '[]' https://github.com loft-sh/demo
  [[ "$output" == *"…\`"* ]]
  [[ "$output" != *"$long"* ]]
}

@test "the state survives a render, even when the command closes an HTML comment" {
  s="$(state '/test-e2e a --> <!-- b' '[{"id":11,"label":"Pro"}]')"
  body="$(render_reply "$s" '[]' https://github.com loft-sh/demo)"
  [ "$(reply_state_decode "$body")" = "$s" ]
  [ "$(head -n1 <<< "$body")" = "<!-- comment-triggered-check:reply:777 -->" ]
}

@test "a body without state is not decoded" {
  run reply_state_decode "just a comment"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "row labels name the run or the repeat" {
  [ "$(run_label Pro "" 1 1)" = "Pro" ]
  [ "$(run_label Platform "" 2 3)" = "Platform, run 2 of 3" ]
  [ "$(run_label Platform 4 1 1)" = "Platform, repeat 4" ]
}

@test "a run URL that is not a plain https link is never rendered" {
  for bad in 'https://e/1)[x](https://evil' 'javascript:alert(1)' 'http://e/1' 'https://e/<b>'; do
    run render_reply "$(state "" '[{"id":11,"label":"Pro"}]')" \
      "[$(check 11 in_progress "" "$bad")]" https://github.com loft-sh/demo
    [[ "$output" == *"- Pro: starting, [view the check](${BASE}/runs/11)"* ]]
    [[ "$output" != *"evil"* && "$output" != *"javascript"* ]]
  done
}

# --- link mode ---------------------------------------------------------------

@test "link stores the run on the check and redraws the reply" {
  seed_reply 555 "$(state "" "$TWO")"
  seed_check 11 in_progress
  seed_check 12 in_progress
  export INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://github.com/loft-sh/demo/actions/runs/99"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .external_id "$MOCK_DIR/checkrun-11.json")" = "555 https://github.com/loft-sh/demo/actions/runs/99" ]
  [[ "$(body_of 555)" == *"- Pro: running, [watch the run](https://github.com/loft-sh/demo/actions/runs/99)"* ]]
  [[ "$(body_of 555)" == *"- OSS: starting,"* ]]
  [ "$(calls_matching "PATCH repos/loft-sh/demo/issues/comments/555")" -eq 1 ]
}

@test "a job that overwrites the reply with an older view restores the other job's link" {
  # Job A links run 11 and returns. Job B read the reply before A wrote, so its
  # write drops A's link. B's own read-back must still draw it.
  seed_reply 555 "$(state "" "$TWO")"
  seed_check 11 in_progress
  seed_check 12 in_progress
  stale="$(body_of 555)"
  INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://e/a" run bash "$LINK"
  [[ "$(body_of 555)" == *"- Pro: running, [watch the run](https://e/a)"* ]]

  printf '%s' "$stale" > "$MOCK_DIR/comment-555"
  INPUT_CHECK_RUN_ID=12 INPUT_RUN_URL="https://e/b" run bash "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(body_of 555)" == *"- Pro: running, [watch the run](https://e/a)"* ]]
  [[ "$(body_of 555)" == *"- OSS: running, [watch the run](https://e/b)"* ]]
}

@test "link edits the check with the token that opened it" {
  seed_reply 555 "$(state "" '[{"id":11,"label":"Pro"}]')"
  check 11 in_progress | jq -c '.app.slug = "ci-app"' > "$MOCK_DIR/checkrun-11.json"
  export INPUT_APP_TOKEN="app" INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://e/1"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [ "$(tokens_for "PATCH repos/loft-sh/demo/check-runs/11")" = "app" ]
  [ "$(tokens_for "PATCH repos/loft-sh/demo/issues/comments/555")" = "x" ]
}

@test "link does nothing for a check without a reply" {
  export INPUT_CHECK_RUN_ID=4242 INPUT_RUN_URL="https://github.com/loft-sh/demo/actions/runs/99"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [ "$(calls_matching "issues/comments")" -eq 0 ]
  [ "$(calls_matching "PATCH")" -eq 0 ]
}

@test "link refuses a run URL that could break the markdown link" {
  export INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://e/1) [x](https://evil"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a plain https URL"* ]]
  [ "$(call_count)" -eq 0 ]
}

@test "link without a check id is a no-op" {
  export INPUT_CHECK_RUN_ID="" INPUT_RUN_URL="https://e/1"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 0 ]
}

@test "link never fails the caller when the check cannot be edited" {
  seed_reply 555 "$(state "" '[{"id":11,"label":"Pro"}]')"
  seed_check 11 in_progress
  export GH_MOCK_PATCH_FAIL=1 INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://e/1"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not store the run link on check-run 11"* ]]
}

@test "link retries a reply it cannot edit and never fails the caller" {
  seed_reply 555 "$(state "" '[{"id":11,"label":"Pro"}]')"
  seed_check 11 in_progress
  export GH_MOCK_COMMENT_PATCH_FAIL=1 INPUT_REPLY_ATTEMPTS=2
  export INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://github.com/loft-sh/demo/actions/runs/99"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [ "$(calls_matching "PATCH repos/loft-sh/demo/issues/comments/555")" -eq 2 ]
  [[ "$output" == *"could not update reply comment 555"* ]]
}

# --- redraws -----------------------------------------------------------------

@test "a redraw that changes nothing writes nothing" {
  seed_check 11 in_progress "" https://e/1
  render_reply "$(state "" '[{"id":11,"label":"Pro"}]')" "[$(check 11 in_progress "" https://e/1)]" \
    https://github.com loft-sh/demo > "$MOCK_DIR/comment-555"
  # shellcheck source=../src/reply.sh
  source "$BATS_TEST_DIRNAME/../src/reply.sh"
  run reply_refresh loft-sh/demo 555
  [ "$status" -eq 0 ]
  [ "$(calls_matching "PATCH")" -eq 0 ]
}

@test "a redraw reads back and stops once the reply matches" {
  seed_reply 555 "$(state "" '[{"id":11,"label":"Pro"}]')"
  seed_check 11 completed success https://e/1
  # shellcheck source=../src/reply.sh
  source "$BATS_TEST_DIRNAME/../src/reply.sh"
  run reply_refresh loft-sh/demo 555
  [ "$status" -eq 0 ]
  [ "$(calls_matching "PATCH")" -eq 1 ]
  [[ "$(body_of 555)" == *"- Pro: passed, [view the run](https://e/1)"* ]]
}

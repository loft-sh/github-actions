#!/usr/bin/env bats
# The reply comment: pure rendering, link mode, and redraws against a stubbed gh.

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
  jq -c -n --arg cmd "${1:-/test-e2e snapshots}" '{v: 2, comment_id: 777, command: $cmd, sha: "abc1234def56"}'
}
# row <id> <label> <status> [conclusion] [url] — one reply row, as reply_rows gives it.
row() {
  jq -c -n --argjson id "$1" --arg l "$2" --arg s "$3" --arg c "${4-}" --arg u "${5-}" \
    '{id: $id, label: $l, status: $s, conclusion: (if $c == "" then null else $c end), head_sha: "abc1234def56", url: $u}'
}
# seed_check <id> <label> <status> [conclusion] [url] [attempt] [reply] — a
# check-run on the commit, stamped for reply 555 unless told otherwise.
seed_check() {
  jq -c -n --argjson id "$1" --arg l "$2" --arg s "$3" --arg c "${4-}" --arg u "${5-}" \
    --argjson a "${6:-1}" --argjson r "${7:-555}" '
    {id: $id, name: ("check-" + ($id | tostring)), status: $s, conclusion: (if $c == "" then null else $c end),
     head_sha: "abc1234def56", app: {slug: "github-actions"},
     external_id: ({r: $r, a: $a, l: $l} + (if $u == "" then {} else {u: $u} end) | tojson)}
  ' > "$MOCK_DIR/checkrun-$1.json"
}
seed_reply() { render_reply "$(state)" '[]' https://github.com loft-sh/demo > "$MOCK_DIR/comment-555"; }
body() { cat "$MOCK_DIR/comment-555"; }
refresh() {
  # shellcheck source=../src/reply.sh
  source "$BATS_TEST_DIRNAME/../src/reply.sh"
  reply_refresh loft-sh/demo 555 "$@"
}

# --- rendering ---------------------------------------------------------------

@test "a running run with a link says running and links the run" {
  run render_reply "$(state)" "[$(row 11 Pro in_progress "" https://example.com/run/1)]" https://github.com loft-sh/demo
  [[ "$output" == *':rocket: `/test-e2e snapshots` started 1 run on `abc1234`. This comment updates when it finishes.'* ]]
  [[ "$output" == *"- Pro: running, [watch the run](https://example.com/run/1)"* ]]
}

@test "a run with no link yet points at its check" {
  run render_reply "$(state)" "[$(row 11 Pro in_progress),$(row 12 OSS queued)]" https://github.com loft-sh/demo
  [[ "$output" == *"started 2 runs"*"when they finish."* ]]
  [[ "$output" == *"- OSS: starting, [view the check](${BASE}/runs/12)"* ]]
}

@test "a reply with no rows yet says the command is starting, never that it failed" {
  run render_reply "$(state)" '[]' https://github.com loft-sh/demo
  [[ "$output" == *':rocket: `/test-e2e snapshots` is starting on `abc1234`.'* ]]
  [[ "$output" != *":x:"* ]]
}

@test "finished runs show their outcome and a check mark when none failed" {
  run render_reply "$(state)" \
    "[$(row 11 Pro completed success https://e/1),$(row 12 OSS completed neutral https://e/2)]" https://github.com loft-sh/demo
  [[ "$output" == *':white_check_mark: `/test-e2e snapshots` finished on `abc1234`.'* ]]
  [[ "$output" == *"- Pro: passed, [view the run](https://e/1)"* ]]
  [[ "$output" == *"- OSS: nothing to run, [view the run](https://e/2)"* ]]
}

@test "any failed, timed out or cancelled run gives a cross" {
  for pair in failure:failed timed_out:"timed out" cancelled:cancelled; do
    c="${pair%%:*}" phrase="${pair#*:}"
    run render_reply "$(state)" \
      "[$(row 11 Pro completed success https://e/1),$(row 12 OSS completed "$c" https://e/2)]" https://github.com loft-sh/demo
    [[ "$output" == *":x: "*"finished"* ]]
    [[ "$output" == *"- OSS: ${phrase//\"/}, [view the run](https://e/2)"* ]]
  done
}

@test "the headline waits for the last run" {
  run render_reply "$(state)" \
    "[$(row 11 Pro completed failure https://e/1),$(row 12 OSS in_progress "" https://e/2)]" https://github.com loft-sh/demo
  [[ "$output" == *":rocket: "* ]]
  [[ "$output" == *"- Pro: failed,"* ]]
}

@test "a failed check that never got a run did not start" {
  run render_reply "$(state)" "[$(row 13 "Platform, run 3 of 3" completed failure)]" https://github.com loft-sh/demo
  [[ "$output" == *"- Platform, run 3 of 3: did not start, [see why](${BASE}/runs/13)"* ]]
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
  s="$(state '/test-e2e a --> <!-- b')"
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
  for bad in 'https://e/1)[x](https://evil' 'javascript:alert(1)' 'http://e/1' 'https://e/<b>' 'https://e/1?x=[a]'; do
    run render_reply "$(state)" "[$(row 11 Pro in_progress "" "$bad")]" https://github.com loft-sh/demo
    [[ "$output" == *"- Pro: starting, [view the check](${BASE}/runs/11)"* ]]
    [[ "$output" != *"evil"* && "$output" != *"javascript"* ]]
    run is_run_url "$bad"
    [ "$status" -ne 0 ]
  done
  is_run_url "https://github.com/loft-sh/demo/actions/runs/42"
}

# --- which checks are rows ---------------------------------------------------

@test "rows are this reply's checks from the newest attempt, oldest first" {
  seed_check 21 OSS in_progress "" "" 2
  seed_check 20 Pro in_progress "" "" 2
  seed_check 11 Pro completed failure "" 1
  seed_check 30 Other in_progress "" "" 9 999
  printf '%s' '{"id":31,"external_id":"555"}' > "$MOCK_DIR/checkrun-31.json"
  run reply_rows 555 "$(cat "$MOCK_DIR"/checkrun-*.json | jq -s .)"
  [ "$(jq -c 'map([.id, .label])' <<< "$output")" = '[[20,"Pro"],[21,"OSS"]]' ]
}

# --- redraws -----------------------------------------------------------------

@test "a redraw draws the checks into the reply and stops once it matches" {
  seed_reply
  seed_check 11 Pro completed success https://e/1
  run refresh
  [ "$status" -eq 0 ]
  [ "$(calls_matching "PATCH")" -eq 1 ]
  [[ "$(body)" == *"- Pro: passed, [view the run](https://e/1)"* ]]
}

@test "a redraw works when the commit's checks are larger than one argument may be" {
  # Linux caps a single argument at 128 KiB; a busy pull request's commit
  # carries more check-run JSON than that.
  seed_reply
  seed_check 11 Pro completed success https://e/1
  big="$(printf 'x%.0s' {1..4096})"
  for id in $(seq 100 159); do
    jq -c -n --argjson id "$id" --arg t "$big" \
      '{id: $id, name: "other", status: "completed", conclusion: "success", head_sha: "abc1234def56",
        app: {slug: "other"}, output: {text: $t}}' > "$MOCK_DIR/checkrun-$id.json"
  done
  run refresh
  [ "$status" -eq 0 ]
  [[ "$(body)" == *"- Pro: passed, [view the run](https://e/1)"* ]]
}

@test "a redraw leaves the reply alone when the checks cannot be merged" {
  seed_reply
  seed_check 11 Pro completed success https://e/1
  before="$(body)"
  # shellcheck source=../src/reply.sh
  source "$BATS_TEST_DIRNAME/../src/reply.sh"
  reply_checks_on() { printf '{}\n'; }
  run reply_refresh loft-sh/demo 555
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not merge the checks"* ]]
  [ "$(body)" = "$before" ]
}

@test "a redraw that changes nothing writes nothing" {
  seed_check 11 Pro in_progress "" https://e/1
  render_reply "$(state)" "[$(row 11 Pro in_progress "" https://e/1)]" https://github.com loft-sh/demo > "$MOCK_DIR/comment-555"
  run refresh
  [ "$status" -eq 0 ]
  [ "$(calls_matching "PATCH")" -eq 0 ]
}

@test "a stale write that dropped a row is restored by the next redraw" {
  # A finish from the old attempt writes back a reply without the new rows.
  seed_check 11 Pro completed cancelled https://e/old 1
  seed_check 20 Pro in_progress "" https://e/new 2
  render_reply "$(state)" "[$(row 11 Pro completed cancelled https://e/old)]" https://github.com loft-sh/demo > "$MOCK_DIR/comment-555"
  run refresh
  [ "$status" -eq 0 ]
  [[ "$(body)" == *"- Pro: running, [watch the run](https://e/new)"* ]]
  [[ "$(body)" != *"e/old"* ]]
}

@test "a redraw finds the checks of a re-run on a newer commit" {
  seed_reply
  seed_check 11 Pro completed success https://e/1 1
  jq -c '.id = 20 | .head_sha = "def5678aaaa" | .status = "in_progress" | .conclusion = null
         | .external_id = ({r: 555, a: 2, l: "Pro"} | tojson)' \
    "$MOCK_DIR/checkrun-11.json" > "$MOCK_DIR/checkrun-20.json"
  run refresh def5678aaaa
  [ "$status" -eq 0 ]
  [[ "$(body)" == *"started 1 run on \`def5678\`"*"runs/20"* ]]
  [ "$(reply_state_decode "$(body)" | jq -r .sha)" = "def5678aaaa" ]
}

@test "an old writer paused across a re-run on a newer commit still draws the newer attempt" {
  # The old writer is attempt 1's finish: its check just completed as
  # cancelled, so its view differs from the reply it read and it will write.
  # Between its read and its write, a re-run on a newer commit opens its check
  # and writes the reply. The old writer only knows the old commit.
  seed_check 11 Pro completed cancelled https://e/old 1
  render_reply "$(state)" "[$(row 11 Pro in_progress "" https://e/old)]" https://github.com loft-sh/demo > "$MOCK_DIR/comment-555"
  export GH_MOCK_PR_JSON='{"head":{"sha":"def5678aaaa","ref":"feature/x","repo":{"full_name":"loft-sh/demo"}},"base":{"ref":"main"},"state":"open"}'
  cat > "$MOCK_DIR/rerun.sh" <<EOF
jq -c -n '{id: 20, name: "check-20", status: "in_progress", conclusion: null, head_sha: "def5678aaaa",
  app: {slug: "github-actions"}, external_id: ({r: 555, a: 2, l: "Pro", u: "https://e/new"} | tojson)}' \
  > "$MOCK_DIR/checkrun-20.json"
printf '%s' "\$(source "$LIB" && render_reply '{"v":2,"comment_id":777,"command":"/test-e2e snapshots","sha":"def5678aaaa"}' \
  '[{"id":20,"label":"Pro","status":"in_progress","conclusion":null,"head_sha":"def5678aaaa","url":"https://e/new"}]' \
  https://github.com loft-sh/demo)" > "$MOCK_DIR/comment-555"
EOF
  export GH_MOCK_AFTER_FIRST_READ="$MOCK_DIR/rerun.sh"
  run refresh abc1234def56
  [ "$status" -eq 0 ]
  [ -f "$MOCK_DIR/after-first-read" ]
  [[ "$(body)" == *"started 1 run on \`def5678\`"* ]]
  [[ "$(body)" == *"- Pro: running, [watch the run](https://e/new)"* ]]
  [[ "$(body)" != *"e/old"* ]]
  [ "$(reply_state_decode "$(body)" | jq -r .sha)" = "def5678aaaa" ]
}

@test "a redraw still works when the pull request cannot be read" {
  seed_reply
  seed_check 11 Pro completed success https://e/1
  export GH_MOCK_PR_FAIL=1
  run refresh
  [ "$status" -eq 0 ]
  [[ "$(body)" == *"- Pro: passed, [view the run](https://e/1)"* ]]
}

@test "a redraw leaves the reply alone when the checks cannot be listed" {
  seed_reply
  before="$(body)"
  export GH_MOCK_LIST_FAIL=1
  run refresh
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not list the checks"* ]]
  [ "$(body)" = "$before" ]
}

# --- link mode ---------------------------------------------------------------

@test "link stores the run on its check and redraws the reply" {
  seed_reply
  seed_check 11 Pro in_progress
  seed_check 12 OSS in_progress
  export INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://github.com/loft-sh/demo/actions/runs/99"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.external_id | fromjson' "$MOCK_DIR/checkrun-11.json")" = '{"r":555,"a":1,"l":"Pro","u":"https://github.com/loft-sh/demo/actions/runs/99"}' ]
  [[ "$(body)" == *"- Pro: running, [watch the run](https://github.com/loft-sh/demo/actions/runs/99)"* ]]
  [[ "$(body)" == *"- OSS: starting,"* ]]
}

@test "a job that overwrites the reply with an older view restores the other job's link" {
  # Job A links run 11 and returns. Job B read the reply before A wrote, so its
  # write drops A's link. B's own read-back must still draw it.
  seed_reply
  seed_check 11 Pro in_progress
  seed_check 12 OSS in_progress
  stale="$(body)"
  INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://e/a" run bash "$LINK"
  [[ "$(body)" == *"- Pro: running, [watch the run](https://e/a)"* ]]

  printf '%s' "$stale" > "$MOCK_DIR/comment-555"
  INPUT_CHECK_RUN_ID=12 INPUT_RUN_URL="https://e/b" run bash "$LINK"
  [ "$status" -eq 0 ]
  [[ "$(body)" == *"- Pro: running, [watch the run](https://e/a)"* ]]
  [[ "$(body)" == *"- OSS: running, [watch the run](https://e/b)"* ]]
}

@test "link edits the check with the token that opened it" {
  seed_reply
  seed_check 11 Pro in_progress
  jq -c '.app.slug = "ci-app"' "$MOCK_DIR/checkrun-11.json" > "$MOCK_DIR/x" && mv "$MOCK_DIR/x" "$MOCK_DIR/checkrun-11.json"
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

@test "link refuses a run URL the reply would not draw" {
  for bad in "https://e/1) [x](https://evil" "https://e/1?x=[a]"; do
    export INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="$bad"
    run bash "$LINK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a plain https URL"* ]]
  done
  [ "$(call_count)" -eq 0 ]
}

@test "link without a check id is a no-op" {
  export INPUT_CHECK_RUN_ID="" INPUT_RUN_URL="https://e/1"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 0 ]
}

@test "link never fails the caller when the check cannot be edited" {
  seed_reply
  seed_check 11 Pro in_progress
  export GH_MOCK_PATCH_FAIL=1 INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://e/1"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not store the run link on check-run 11"* ]]
}

@test "link retries a reply it cannot edit and never fails the caller" {
  seed_reply
  seed_check 11 Pro in_progress
  export GH_MOCK_COMMENT_PATCH_FAIL=1 INPUT_REPLY_ATTEMPTS=2
  export INPUT_CHECK_RUN_ID=11 INPUT_RUN_URL="https://github.com/loft-sh/demo/actions/runs/99"
  run bash "$LINK"
  [ "$status" -eq 0 ]
  [ "$(calls_matching "PATCH repos/loft-sh/demo/issues/comments/555")" -eq 2 ]
  [[ "$output" == *"could not update reply comment 555"* ]]
}

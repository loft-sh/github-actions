#!/usr/bin/env bats
# Tests for upsert-comment.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/upsert-comment.sh"
MARKER='<!-- e2e-status -->'
AUTHOR='github-actions[bot]'

load gh_mock

setup() {
  setup_gh_mock
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  export GH_TOKEN="fake-token"
  export INPUT_MARKER="$MARKER"
  export INPUT_PR_NUMBER="42"
  export INPUT_REPO="owner/repo"
  export INPUT_EXPECTED_AUTHOR="$AUTHOR"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
  teardown_gh_mock
}

kv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1; }
last_body() { awk 'BEGIN{RS="---END---\n"} END{printf "%s", $0}' "$GH_MOCK_BODY_LOG"; }

@test "no existing comment → creates and emits action-taken=created" {
  export GH_MOCK_LIST_JSON='[]'
  export GH_MOCK_CREATE_JSON='{"id": 12345}'
  export INPUT_BODY="hello world"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv comment-id)" = "comment-id=12345" ]
  [ "$(kv action-taken)" = "action-taken=created" ]

  # POST was called against the PR comments endpoint
  grep -q '^POST repos/owner/repo/issues/42/comments$' "$GH_MOCK_CALLS"
  # No PATCH happened
  ! grep -q '^PATCH ' "$GH_MOCK_CALLS"
}

@test "existing comment with marker → updates and emits action-taken=updated" {
  export GH_MOCK_LIST_JSON='[
    {"id": 99, "body": "unrelated comment", "user": {"login": "github-actions[bot]"}},
    {"id": 777, "body": "<!-- e2e-status -->\nold body", "user": {"login": "github-actions[bot]"}}
  ]'
  export INPUT_BODY="new body"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv comment-id)" = "comment-id=777" ]
  [ "$(kv action-taken)" = "action-taken=updated" ]

  grep -q '^PATCH repos/owner/repo/issues/comments/777$' "$GH_MOCK_CALLS"
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "marker present but wrong author → creates new comment (squat-resistant)" {
  export GH_MOCK_LIST_JSON='[
    {"id": 555, "body": "<!-- e2e-status -->\nsquatter body", "user": {"login": "evil-user"}}
  ]'
  export GH_MOCK_CREATE_JSON='{"id": 999}'
  export INPUT_BODY="legit status"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv comment-id)" = "comment-id=999" ]
  [ "$(kv action-taken)" = "action-taken=created" ]

  grep -q '^POST repos/owner/repo/issues/42/comments$' "$GH_MOCK_CALLS"
  # Squatter's comment must NOT be patched.
  ! grep -q '^PATCH repos/owner/repo/issues/comments/555$' "$GH_MOCK_CALLS"
}

@test "marker matches across mixed authors → picks the one matching expected-author" {
  export GH_MOCK_LIST_JSON='[
    {"id": 100, "body": "<!-- e2e-status -->\nsquatter", "user": {"login": "evil-user"}},
    {"id": 200, "body": "<!-- e2e-status -->\nlegit",    "user": {"login": "github-actions[bot]"}}
  ]'
  export INPUT_BODY="updated"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv comment-id)" = "comment-id=200" ]
  [ "$(kv action-taken)" = "action-taken=updated" ]
}

@test "custom expected-author (PAT identity) is honored" {
  export INPUT_EXPECTED_AUTHOR="release-bot"
  export GH_MOCK_LIST_JSON='[
    {"id": 11, "body": "<!-- e2e-status -->\nfrom default bot", "user": {"login": "github-actions[bot]"}},
    {"id": 22, "body": "<!-- e2e-status -->\nfrom release bot", "user": {"login": "release-bot"}}
  ]'
  export INPUT_BODY="x"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv comment-id)" = "comment-id=22" ]
  [ "$(kv action-taken)" = "action-taken=updated" ]
}

@test "marker auto-prepended when body does not start with it" {
  export GH_MOCK_LIST_JSON='[]'
  export GH_MOCK_CREATE_JSON='{"id": 1}'
  export INPUT_BODY=$'### header\nline two'

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  body="$(last_body)"
  [[ "$body" == "<!-- e2e-status -->"$'\n'"### header"$'\n'"line two" ]] || {
    printf 'unexpected body: %q\n' "$body"
    return 1
  }
}

@test "marker not duplicated when body already starts with it" {
  export GH_MOCK_LIST_JSON='[]'
  export GH_MOCK_CREATE_JSON='{"id": 1}'
  export INPUT_BODY=$'<!-- e2e-status -->\nbody'

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  body="$(last_body)"
  [[ "$body" == $'<!-- e2e-status -->\nbody' ]] || {
    printf 'unexpected body: %q\n' "$body"
    return 1
  }
  # No double-marker
  occurrences="$(grep -o -- '<!-- e2e-status -->' <<<"$body" | wc -l)"
  [ "$occurrences" -eq 1 ]
}

@test "first matching comment is chosen when multiple have the marker" {
  export GH_MOCK_LIST_JSON='[
    {"id": 100, "body": "<!-- e2e-status -->\nfirst",  "user": {"login": "github-actions[bot]"}},
    {"id": 200, "body": "<!-- e2e-status -->\nsecond", "user": {"login": "github-actions[bot]"}}
  ]'
  export INPUT_BODY="x"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv comment-id)" = "comment-id=100" ]
}

@test "malformed marker fails fast" {
  export INPUT_MARKER="not-an-html-comment"
  export INPUT_BODY="x"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing required env (INPUT_BODY) fails" {
  unset INPUT_BODY
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing required env (INPUT_PR_NUMBER) fails" {
  unset INPUT_PR_NUMBER
  export INPUT_BODY="x"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/approve-pr.sh"
load gh_mock

setup() {
  setup_gh_mock
  export GITHUB_REPOSITORY="owner/repo" PR_NUMBER=42 GH_TOKEN="test-token"
  export PR_HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export GH_MOCK_HEAD_SHA="$PR_HEAD_SHA"
  export GH_MOCK_REVIEW_PAYLOAD="$MOCK_DIR/review.json"
  export GITHUB_OUTPUT="$MOCK_DIR/output"
}
teardown() { teardown_gh_mock; }

@test "approval POST binds the review to the tested commit" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e --arg sha "$PR_HEAD_SHA" '.commit_id == $sha and .event == "APPROVE" and (.body | startswith("Approved by the shared auto-approve workflow"))' "$GH_MOCK_REVIEW_PAYLOAD"
  [[ "$(cat "$GH_MOCK_CALLS")" == *"api repos/owner/repo/pulls/42/reviews --method POST --input -"* ]]
  [[ "$output" == *"approved at the tested commit"* ]]
  [ "$(tail -n 1 "$GITHUB_OUTPUT")" = 'approved=true' ]
}

@test "moved head skips the approval POST" {
  GH_MOCK_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$GH_MOCK_REVIEW_PAYLOAD" ]
  [[ "$output" == *"head changed"* ]]
  [ "$(cat "$GITHUB_OUTPUT")" = 'approved=false' ]
}

@test "unreadable head skips the approval POST" {
  GH_MOCK_PULL_FAIL=always run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$GH_MOCK_REVIEW_PAYLOAD" ]
}

@test "approval API failure stays advisory and omits unsafe error content" {
  GH_MOCK_REVIEW_FAIL=always GH_MOCK_STDERR=$'test-token\n::error::forged%0A' run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not submit approval"* ]]
  [[ "$output" != *"test-token"* && "$output" != *"forged"* ]]
  [ "$(cat "$GITHUB_OUTPUT")" = 'approved=false' ]
}

@test "malformed or mismatched review response never reports success" {
  for response in 'invalid json' '{}' '[]' '{"commit_id":"wrong","state":"APPROVED"}' '{"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"COMMENTED"}'; do
    : > "$GITHUB_OUTPUT"
    GH_MOCK_REVIEW_JSON="$response" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not verify approval"* ]]
    [[ "$output" != *"approved at the tested commit"* ]]
    [ "$(cat "$GITHUB_OUTPUT")" = 'approved=false' ]
  done
}

@test "push racing approval POST cannot move the review to the new commit" {
  GH_MOCK_REVIEW_HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e --arg sha "$PR_HEAD_SHA" '.commit_id == $sha' "$GH_MOCK_REVIEW_PAYLOAD"
  [ "$(tail -n 1 "$GITHUB_OUTPUT")" = 'approved=true' ]
}

@test "invalid SHA or PR number makes no API calls and logs no unsafe input" {
  for field in PR_HEAD_SHA PR_NUMBER; do
    run env "$field"=$'test-token\n::error::forged%0A' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$GH_MOCK_CALLS" ]
    [[ "$output" != *"test-token"* && "$output" != *"forged"* ]]
  done
}

@test "missing required environment fails before making API calls" {
  for field in GH_TOKEN GITHUB_REPOSITORY PR_NUMBER PR_HEAD_SHA; do
    run env -u "$field" "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -s "$GH_MOCK_CALLS" ]
  done
}

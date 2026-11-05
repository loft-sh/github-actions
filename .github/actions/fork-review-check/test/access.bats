#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../src/check-access.sh"

setup() {
  MOCK_DIR=$(mktemp -d)
  export PATH="$MOCK_DIR:$PATH"
  export GH_TOKEN=test-token
  export REPO=loft-sh/kine
  export GITHUB_ACTOR=reviewer
  export CALL_FILE="$MOCK_DIR/call"
  export RESPONSE=write
  export GH_STATUS=0
  cat > "$MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CALL_FILE"
printf '%s\n' "$RESPONSE"
exit "$GH_STATUS"
MOCK
  chmod +x "$MOCK_DIR/gh"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

@test "checks target repository permission access without printing the token" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALL_FILE")" = $'api\nrepos/loft-sh/kine/collaborators/reviewer/permission\n--jq\n.permission' ]
  [[ "$output" == *'lookup succeeded'* ]]
  [[ "$output" != *test-token* ]]
}

@test "a non-collaborator still proves access to the permission endpoint" {
  RESPONSE=none run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "missing dedicated token fails without using the workflow token" {
  GH_TOKEN='' GITHUB_TOKEN=caller-token run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *FORK_REVIEW_READ_TOKEN* ]]
  [ ! -f "$CALL_FILE" ]
}

@test "API denial fails even when the response contains a permission" {
  GH_STATUS=1 RESPONSE=write run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *'Metadata: read'* ]]
}

@test "an empty or unexpected permission fails closed" {
  for response in '' null unknown; do
    RESPONSE="$response" run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *'No collaborator permission returned'* ]]
  done
}

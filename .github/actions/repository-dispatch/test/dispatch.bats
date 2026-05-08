#!/usr/bin/env bats
# Tests for dispatch.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/dispatch.sh"

load gh_mock

setup() {
  setup_gh_mock
  export GH_TOKEN="fake-token"
  export INPUT_TARGET_REPO="loft-sh/vcluster-docs"
  export INPUT_EVENT_TYPE="vcluster-released"
  export INPUT_PAYLOAD='{"version":"v0.42.0","sha":"abc123"}'
}

teardown() {
  teardown_gh_mock
}

last_body() { awk 'BEGIN{RS="---END---\n"} END{printf "%s", $0}' "$GH_MOCK_BODY_LOG"; }

@test "happy path → POST to target /dispatches with event_type and client_payload" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  grep -q '^POST repos/loft-sh/vcluster-docs/dispatches$' "$GH_MOCK_CALLS"

  body="$(last_body)"
  [ "$(jq -r '.event_type' <<<"$body")" = "vcluster-released" ]
  [ "$(jq -r '.client_payload.version' <<<"$body")" = "v0.42.0" ]
  [ "$(jq -r '.client_payload.sha' <<<"$body")" = "abc123" ]
}

@test "missing target-repo → fail fast, no API call" {
  unset INPUT_TARGET_REPO
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "missing event-type → fail fast, no API call" {
  unset INPUT_EVENT_TYPE
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "missing GH_TOKEN → fail fast, no API call" {
  unset GH_TOKEN
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "malformed JSON payload → fail fast, no API call" {
  export INPUT_PAYLOAD='{"unclosed":'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "non-object JSON payload (array) → fail fast, no API call" {
  export INPUT_PAYLOAD='["a","b"]'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "non-object JSON payload (scalar) → fail fast, no API call" {
  export INPUT_PAYLOAD='"just a string"'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "empty target-repo → fail fast" {
  export INPUT_TARGET_REPO=""
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "empty event-type → fail fast" {
  export INPUT_EVENT_TYPE=""
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
}

@test "default payload is {} when input is empty string" {
  export INPUT_PAYLOAD=""
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  body="$(last_body)"
  # client_payload should be an empty object (no keys).
  [ "$(jq -r '.client_payload | type' <<<"$body")" = "object" ]
  [ "$(jq -r '.client_payload | keys | length' <<<"$body")" = "0" ]
}

@test "default payload is {} when var is unset" {
  unset INPUT_PAYLOAD
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  body="$(last_body)"
  [ "$(jq -r '.client_payload | type' <<<"$body")" = "object" ]
  [ "$(jq -r '.client_payload | keys | length' <<<"$body")" = "0" ]
}

@test "explicit empty object payload → {} sent" {
  export INPUT_PAYLOAD='{}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  body="$(last_body)"
  [ "$(jq -r '.client_payload | keys | length' <<<"$body")" = "0" ]
}

@test "idempotent: same call twice → both succeed" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # Two POSTs recorded, identical bodies.
  count=$(grep -c '^POST repos/loft-sh/vcluster-docs/dispatches$' "$GH_MOCK_CALLS")
  [ "$count" -eq 2 ]
}

@test "event_type with special characters is preserved verbatim" {
  export INPUT_EVENT_TYPE='vcluster-rc-released'
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  body="$(last_body)"
  [ "$(jq -r '.event_type' <<<"$body")" = "vcluster-rc-released" ]
}

@test "nested payload values survive jq round-trip" {
  export INPUT_PAYLOAD='{"version":"v1.2.3","meta":{"channel":"stable","prerelease":false}}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  body="$(last_body)"
  [ "$(jq -r '.client_payload.meta.channel' <<<"$body")" = "stable" ]
  [ "$(jq -r '.client_payload.meta.prerelease' <<<"$body")" = "false" ]
}

@test "gh failure surfaces non-zero exit" {
  export GH_MOCK_FAIL=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

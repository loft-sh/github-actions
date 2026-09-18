#!/usr/bin/env bats

load gh_mock

QUEUE="$BATS_TEST_DIRNAME/../src/queue-fork.sh"
RESOLVE="$BATS_TEST_DIRNAME/../src/resolve-fork.sh"

setup() {
  setup_gh_mock
  export INPUT_REPO="loft-sh/demo"
  export INPUT_PR_NUMBER="42"
  export INPUT_ACTOR_LOGIN="loft-bot"
  export INPUT_TRUSTED_BOT="loft-bot"
  export GITHUB_OUTPUT="$MOCK_DIR/output"
}

teardown() {
  teardown_gh_mock
}

@test "queue records the exact request and triggers the pull request label" {
  export INPUT_REQUEST_FILTER="core"
  export INPUT_REQUEST_FOCUS="creates a project"
  export INPUT_REQUEST_TARGET="pro"
  export INPUT_REQUEST_HEAD_SHA="abc123"

  run bash "$QUEUE"

  [ "$status" -eq 0 ]
  [ "$(calls_matching '--method POST repos/loft-sh/demo/issues/42/comments')" -eq 1 ]
  [ "$(calls_matching '--method DELETE repos/loft-sh/demo/issues/42/labels/e2e-fork-request')" -eq 0 ]
  [ "$(calls_matching '--method POST repos/loft-sh/demo/issues/42/labels')" -eq 1 ]
  grep -Fq '"filter":"core"' "$GH_MOCK_CALLS"
  grep -Fq '"focus":"creates a project"' "$GH_MOCK_CALLS"
  grep -Fq '"target":"pro"' "$GH_MOCK_CALLS"
  grep -Fq '"head-sha":"abc123"' "$GH_MOCK_CALLS"
}

@test "queue updates its request comment and toggles an existing label" {
  export INPUT_REQUEST_FILTER="snapshots"
  export INPUT_REQUEST_HEAD_SHA="def456"
  export GH_MOCK_COMMENTS_JSON='[[{"id":99,"user":{"login":"loft-bot"},"body":"<!-- e2e-fork-request -->\nold"}]]'
  export GH_MOCK_LABELS_JSON='[[{"name":"e2e-fork-request"}]]'

  run bash "$QUEUE"

  [ "$status" -eq 0 ]
  [ "$(calls_matching '--method PATCH repos/loft-sh/demo/issues/comments/99')" -eq 1 ]
  [ "$(calls_matching '--method POST repos/loft-sh/demo/issues/42/comments')" -eq 0 ]
  [ "$(calls_matching '--method DELETE repos/loft-sh/demo/issues/42/labels/e2e-fork-request')" -eq 1 ]
  [ "$(calls_matching '--method POST repos/loft-sh/demo/issues/42/labels')" -eq 1 ]
}

@test "queue stops if an existing request label cannot be removed" {
  export INPUT_REQUEST_FILTER="core"
  export INPUT_REQUEST_HEAD_SHA="abc123"
  export GH_MOCK_LABELS_JSON='[[{"name":"e2e-fork-request"}]]'
  export GH_MOCK_LABEL_DELETE_FAIL=1

  run bash "$QUEUE"

  [ "$status" -ne 0 ]
  [[ "$output" == *"label delete failed"* ]]
  [ "$(calls_matching '/issues/42/comments')" -eq 0 ]
  [ "$(calls_matching '--method POST repos/loft-sh/demo/issues/42/labels')" -eq 0 ]
}

@test "resolve returns the request pinned to the pull request head" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="labeled"
  export INPUT_EVENT_LABEL="e2e-fork-request"
  export INPUT_PR_HEAD_SHA="abc123"
  export GH_MOCK_COMMENTS_JSON='[[{"user":{"login":"loft-bot"},"body":"<!-- e2e-fork-request -->\n\n```json\n{\"filter\":\"core\",\"focus\":\"creates a project\",\"target\":\"pro\",\"head-sha\":\"abc123\"}\n```"}]]'

  run bash "$RESOLVE"

  [ "$status" -eq 0 ]
  grep -Fxq 'filter=core' "$GITHUB_OUTPUT"
  grep -Fxq 'focus=creates a project' "$GITHUB_OUTPUT"
  grep -Fxq 'target=pro' "$GITHUB_OUTPUT"
}

@test "resolve refuses a request for a different pull request head" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="labeled"
  export INPUT_EVENT_LABEL="e2e-fork-request"
  export INPUT_PR_HEAD_SHA="new456"
  export GH_MOCK_COMMENTS_JSON='[[{"user":{"login":"loft-bot"},"body":"<!-- e2e-fork-request -->\n\n```json\n{\"filter\":\"core\",\"focus\":\"\",\"target\":\"\",\"head-sha\":\"abc123\"}\n```"}]]'

  run bash "$RESOLVE"

  [ "$status" -ne 0 ]
  [[ "$output" == *"pull request changed after the command was requested"* ]]
}

@test "resolve refuses a label not applied by the trusted bot" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="labeled"
  export INPUT_EVENT_LABEL="e2e-fork-request"
  export INPUT_PR_HEAD_SHA="abc123"
  export INPUT_ACTOR_LOGIN="someone-else"

  run bash "$RESOLVE"

  [ "$status" -ne 0 ]
  [[ "$output" == *"was not queued by loft-bot"* ]]
  [ "$(call_count)" -eq 0 ]
}

@test "resolve ignores a forged request comment" {
  export INPUT_EVENT_NAME="pull_request"
  export INPUT_EVENT_ACTION="labeled"
  export INPUT_EVENT_LABEL="e2e-fork-request"
  export INPUT_PR_HEAD_SHA="abc123"
  export GH_MOCK_COMMENTS_JSON='[[{"user":{"login":"fork-author"},"body":"<!-- e2e-fork-request -->\n\n```json\n{\"filter\":\"core\",\"focus\":\"\",\"target\":\"\",\"head-sha\":\"abc123\"}\n```"}]]'

  run bash "$RESOLVE"

  [ "$status" -ne 0 ]
  [[ "$output" == *"no queued E2E request was found"* ]]
}

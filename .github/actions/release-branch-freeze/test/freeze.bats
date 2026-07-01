#!/usr/bin/env bats
# Tests for freeze.sh. Stubs `gh` (see gh_mock.bash); uses the real jq so the
# payload built by the script is validated end-to-end.

SCRIPT="$BATS_TEST_DIRNAME/../src/freeze.sh"

load gh_mock

setup() {
  setup_gh_mock
  export GH_TOKEN="fake-token"
  export INPUT_OPERATION="freeze"
  export INPUT_REPOSITORY="loft-sh/vcluster-pro"
  export INPUT_BRANCH="v0.36"
  export INPUT_BYPASS_TEAM_ID="16898535"
  export INPUT_ENFORCEMENT=""
  export INPUT_RULESET_NAME=""
  export GITHUB_OUTPUT="$MOCK_DIR/output"
  : > "$GITHUB_OUTPUT"
}

teardown() {
  teardown_gh_mock
}

# Last non-empty request body recorded by the gh mock.
last_body() {
  awk 'BEGIN{RS="---END---\n"} NF{b=$0} END{printf "%s", b}' "$GH_MOCK_BODY_LOG"
}

# --- required input validation ----------------------------------------------

@test "missing GH_TOKEN fails fast, no api call" {
  unset GH_TOKEN
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$GH_MOCK_CALLS" ]
}

@test "missing operation fails fast" {
  unset INPUT_OPERATION
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing repository fails fast" {
  unset INPUT_REPOSITORY
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "freeze without branch fails fast" {
  unset INPUT_BRANCH
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "unknown operation fails fast" {
  export INPUT_OPERATION="frobnicate"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"operation must be"* ]]
}

# --- freeze input validation ------------------------------------------------

@test "freeze without bypass-team-id fails, no write call" {
  unset INPUT_BYPASS_TEAM_ID
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -qE '^(POST|PUT) ' "$GH_MOCK_CALLS"
}

@test "freeze with non-numeric bypass-team-id fails" {
  export INPUT_BYPASS_TEAM_ID="eng-tech-leads"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"numeric"* ]]
}

@test "freeze with invalid enforcement fails" {
  export INPUT_ENFORCEMENT="on"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"enforcement must be"* ]]
}

# --- freeze: create path ----------------------------------------------------

@test "freeze creates ruleset when none exists, with the right shape" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^POST repos/loft-sh/vcluster-pro/rulesets$' "$GH_MOCK_CALLS"
  body="$(last_body)"
  [ "$(jq -r '.name' <<<"$body")" = "release-branch-code-freeze" ]
  [ "$(jq -r '.target' <<<"$body")" = "branch" ]
  [ "$(jq -r '.enforcement' <<<"$body")" = "active" ]
  [ "$(jq -r '.rules[0].type' <<<"$body")" = "update" ]
  [ "$(jq -r '.conditions.ref_name.include[0]' <<<"$body")" = "refs/heads/v0.36" ]
  [ "$(jq -r '.bypass_actors[0].actor_type' <<<"$body")" = "Team" ]
  [ "$(jq -r '.bypass_actors[0].actor_id' <<<"$body")" = "16898535" ]
  [ "$(jq -r '.bypass_actors[0].bypass_mode' <<<"$body")" = "always" ]
  grep -q '^ruleset-id=12345$' "$GITHUB_OUTPUT"
}

@test "freeze defaults enforcement to active" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.enforcement' <<<"$(last_body)")" = "active" ]
}

@test "freeze honors enforcement=evaluate for a dry run" {
  export INPUT_ENFORCEMENT="evaluate"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.enforcement' <<<"$(last_body)")" = "evaluate" ]
}

# --- freeze: update (upsert) path -------------------------------------------

@test "freeze updates the existing ruleset instead of creating a second" {
  export GH_MOCK_RULESETS='[{"id":777,"name":"release-branch-code-freeze"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^PUT repos/loft-sh/vcluster-pro/rulesets/777$' "$GH_MOCK_CALLS"
  ! grep -q '^POST ' "$GH_MOCK_CALLS"
  grep -q '^ruleset-id=777$' "$GITHUB_OUTPUT"
}

@test "freeze re-points the ref to the given branch on update" {
  export GH_MOCK_RULESETS='[{"id":777,"name":"release-branch-code-freeze"}]'
  export INPUT_BRANCH="release-4.11"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.conditions.ref_name.include[0]' <<<"$(last_body)")" = "refs/heads/release-4.11" ]
}

@test "custom ruleset-name is matched and written" {
  export INPUT_RULESET_NAME="freeze-v0.36"
  export GH_MOCK_RULESETS='[{"id":9,"name":"freeze-v0.36"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^PUT repos/loft-sh/vcluster-pro/rulesets/9$' "$GH_MOCK_CALLS"
  [ "$(jq -r '.name' <<<"$(last_body)")" = "freeze-v0.36" ]
}

# --- unfreeze ---------------------------------------------------------------

@test "unfreeze disables the existing ruleset" {
  export INPUT_OPERATION="unfreeze"
  export GH_MOCK_RULESETS='[{"id":777,"name":"release-branch-code-freeze"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^PUT repos/loft-sh/vcluster-pro/rulesets/777$' "$GH_MOCK_CALLS"
  [[ "$output" == *"disabled"* ]]
}

@test "unfreeze is a no-op when no ruleset exists" {
  export INPUT_OPERATION="unfreeze"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qE '^(POST|PUT) ' "$GH_MOCK_CALLS"
  [[ "$output" == *"nothing to unfreeze"* ]]
}

@test "unfreeze requires neither branch nor bypass-team-id" {
  export INPUT_OPERATION="unfreeze"
  unset INPUT_BYPASS_TEAM_ID
  unset INPUT_BRANCH
  export GH_MOCK_RULESETS='[{"id":5,"name":"release-branch-code-freeze"}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^PUT repos/loft-sh/vcluster-pro/rulesets/5$' "$GH_MOCK_CALLS"
}

# --- error propagation ------------------------------------------------------

@test "gh failure surfaces a non-zero exit" {
  export GH_MOCK_FAIL=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

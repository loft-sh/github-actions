#!/usr/bin/env bats
# Tests for check-eligibility.sh
#
# Covers the decision table used by the auto-approve-bot-prs reusable workflow:
# trusted authors × title/branch eligibility patterns. Regression coverage
# for DEVOPS-749 (dependabot[bot] must be acceptable as a trusted author).

SCRIPT="$BATS_TEST_DIRNAME/../check-eligibility.sh"

# Default trusted list matches what callers pass when they want the full set.
DEFAULT_TRUSTED='renovate[bot],loft-bot,github-actions[bot],dependabot[bot]'

setup() {
  export GITHUB_OUTPUT="$(mktemp)"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

# Helper: run script with overridable env inputs.
run_check() {
  local trusted="${1:-$DEFAULT_TRUSTED}" author="$2" title="$3" branch="$4"
  run env \
    TRUSTED_AUTHORS="$trusted" \
    PR_AUTHOR="$author" \
    PR_TITLE="$title" \
    PR_BRANCH="$branch" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    "$SCRIPT"
}

assert_output_kv() {
  local key="$1" expected="$2"
  local actual
  actual=$(grep "^${key}=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-)
  if [ "$actual" != "$expected" ]; then
    echo "Expected ${key}='${expected}', got '${actual}'"
    echo "GITHUB_OUTPUT contents:"
    cat "$GITHUB_OUTPUT"
    return 1
  fi
}

# --- Trusted-author matching ------------------------------------------------

@test "dependabot[bot] is trusted when listed (DEVOPS-749 regression)" {
  run_check "$DEFAULT_TRUSTED" 'dependabot[bot]' 'chore(deps): bump foo' 'dependabot/npm/foo-1.2.3'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  assert_output_kv reason "chore PR"
}

@test "dependabot[bot] is rejected when not in list (default upstream behavior)" {
  run_check 'renovate[bot],loft-bot,github-actions[bot]' 'dependabot[bot]' 'chore(deps): bump foo' 'dependabot/npm/foo-1.2.3'
  [ "$status" -eq 0 ]
  assert_output_kv eligible false
  assert_output_kv reason ""
}

@test "renovate[bot] is trusted" {
  run_check "$DEFAULT_TRUSTED" 'renovate[bot]' 'chore(deps): bump bar' 'renovate/bar-2.0.0'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  assert_output_kv reason "chore PR"
}

@test "loft-bot is trusted" {
  run_check "$DEFAULT_TRUSTED" 'loft-bot' 'chore: sync partials' 'update-platform-version-4.6.0'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  # update-platform-version branch wins over chore title because the title
  # check is evaluated first — both lead to eligible=true; verify the reason
  # matches whichever branch the logic picks so this test stays a pure
  # behaviour lock-in.
  assert_output_kv reason "chore PR"
}

@test "github-actions[bot] is trusted" {
  run_check "$DEFAULT_TRUSTED" 'github-actions[bot]' 'chore: rebuild' 'gh-actions/rebuild'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
}

@test "unknown author is rejected even with matching title" {
  run_check "$DEFAULT_TRUSTED" 'random-user' 'chore(deps): bump something' 'feature/foo'
  [ "$status" -eq 0 ]
  assert_output_kv eligible false
  assert_output_kv reason ""
}

@test "partial-match author is rejected (exact-match only)" {
  # 'dependabot' is a substring of 'dependabot[bot]' but must not match.
  run_check 'dependabot,loft-bot' 'dependabot[bot]' 'chore: foo' 'foo'
  [ "$status" -eq 0 ]
  assert_output_kv eligible false
}

# --- Title / branch eligibility patterns ------------------------------------

@test "title 'chore:' is eligible" {
  run_check "$DEFAULT_TRUSTED" 'dependabot[bot]' 'chore: update lockfile' 'feature/foo'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  assert_output_kv reason "chore PR"
}

@test "title 'chore(deps):' is eligible" {
  run_check "$DEFAULT_TRUSTED" 'dependabot[bot]' 'chore(deps): bump x to y' 'feature/foo'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  assert_output_kv reason "chore PR"
}

@test "title 'fix(deps):' is eligible" {
  run_check "$DEFAULT_TRUSTED" 'dependabot[bot]' 'fix(deps): patch cve' 'feature/foo'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  assert_output_kv reason "dependency fix PR"
}

@test "branch 'backport/' is eligible" {
  run_check "$DEFAULT_TRUSTED" 'loft-bot' 'whatever title' 'backport/v1.2-something'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  assert_output_kv reason "backport PR"
}

@test "branch 'renovate/' is eligible" {
  run_check "$DEFAULT_TRUSTED" 'renovate[bot]' 'any title' 'renovate/foo-digest'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  assert_output_kv reason "renovate PR"
}

@test "branch 'update-platform-version-' is eligible" {
  run_check "$DEFAULT_TRUSTED" 'loft-bot' 'bump platform' 'update-platform-version-4.6.0'
  [ "$status" -eq 0 ]
  assert_output_kv eligible true
  assert_output_kv reason "platform version update PR"
}

@test "trusted author with feat-title is NOT eligible" {
  run_check "$DEFAULT_TRUSTED" 'dependabot[bot]' 'feat: unrelated work' 'feature/foo'
  [ "$status" -eq 0 ]
  assert_output_kv eligible false
  assert_output_kv reason ""
}

@test "trusted author with empty title/branch is NOT eligible" {
  run_check "$DEFAULT_TRUSTED" 'dependabot[bot]' '' ''
  [ "$status" -eq 0 ]
  assert_output_kv eligible false
  assert_output_kv reason ""
}

# --- Input validation -------------------------------------------------------

@test "missing TRUSTED_AUTHORS fails" {
  run env -u TRUSTED_AUTHORS PR_AUTHOR=x PR_TITLE=y PR_BRANCH=z "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing PR_AUTHOR fails" {
  run env -u PR_AUTHOR TRUSTED_AUTHORS="$DEFAULT_TRUSTED" PR_TITLE=y PR_BRANCH=z "$SCRIPT"
  [ "$status" -ne 0 ]
}

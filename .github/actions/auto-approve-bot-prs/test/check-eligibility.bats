#!/usr/bin/env bats
# Decision-table coverage for check-eligibility.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/check-eligibility.sh"
DEFAULT='renovate[bot],loft-bot,github-actions[bot],dependabot[bot]'

setup() { export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"; }
teardown() { rm -f "$GITHUB_OUTPUT"; }

run_script() {
  run env \
    TRUSTED_AUTHORS="$1" PR_AUTHOR="$2" PR_TITLE="$3" PR_BRANCH="$4" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
}

assert_kv() {
  local want="$1=$2" actual
  actual=$(grep "^$1=" "$GITHUB_OUTPUT" | tail -n1)
  [ "$actual" = "$want" ] || { echo "want: $want"; echo "got:  $actual"; cat "$GITHUB_OUTPUT"; return 1; }
}

@test "dependabot[bot] trusted + chore(deps) title → eligible" {
  run_script "$DEFAULT" 'dependabot[bot]' 'chore(deps): bump foo' 'dependabot/npm/foo'
  [ "$status" -eq 0 ]; assert_kv eligible true
}

@test "dependabot[bot] not in list → eligible=false" {
  run_script 'renovate[bot],loft-bot' 'dependabot[bot]' 'chore(deps): bump' 'x'
  [ "$status" -eq 0 ]; assert_kv eligible false
}

@test "chore: title → eligible" {
  run_script "$DEFAULT" 'loft-bot' 'chore: update' 'x'; assert_kv eligible true
}

@test "fix(deps): title → eligible" {
  run_script "$DEFAULT" 'loft-bot' 'fix(deps): cve' 'x'; assert_kv eligible true
}

@test "backport/ branch → eligible" {
  run_script "$DEFAULT" 'loft-bot' 'anything' 'backport/v1.2'; assert_kv eligible true
}

@test "renovate/ branch → eligible" {
  run_script "$DEFAULT" 'renovate[bot]' 'anything' 'renovate/pkg'; assert_kv eligible true
}

@test "update-platform-version- branch (stable) → eligible" {
  run_script "$DEFAULT" 'loft-bot' 'anything' 'update-platform-version-4.6.0'; assert_kv eligible true
}

@test "update-platform-version- branch (alpha) → not eligible" {
  run_script "$DEFAULT" 'loft-bot' 'chore: update platform version to v4.9.0-alpha.2' 'update-platform-version-v4.9.0-alpha.2'
  [ "$status" -eq 0 ]; assert_kv eligible false
}

@test "update-platform-version- branch (beta) → not eligible" {
  run_script "$DEFAULT" 'loft-bot' 'chore: update platform version to v4.9.0-beta.1' 'update-platform-version-v4.9.0-beta.1'
  [ "$status" -eq 0 ]; assert_kv eligible false
}

@test "update-platform-version- branch (rc) → not eligible" {
  run_script "$DEFAULT" 'loft-bot' 'chore: update platform version to v4.9.0-rc.1' 'update-platform-version-v4.9.0-rc.1'
  [ "$status" -eq 0 ]; assert_kv eligible false
}

@test "feat: title on trusted author → not eligible" {
  run_script "$DEFAULT" 'dependabot[bot]' 'feat: new' 'feature/foo'; assert_kv eligible false
}

@test "untrusted author + chore title → not eligible" {
  run_script "$DEFAULT" 'random-user' 'chore: x' 'x'; assert_kv eligible false
}

@test "exact-match author only (no substring)" {
  run_script 'dependabot,loft-bot' 'dependabot[bot]' 'chore: x' 'x'; assert_kv eligible false
}

@test "missing TRUSTED_AUTHORS fails" {
  run env -u TRUSTED_AUTHORS PR_AUTHOR=x PR_TITLE=y PR_BRANCH=z "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing PR_AUTHOR fails" {
  run env -u PR_AUTHOR TRUSTED_AUTHORS="$DEFAULT" PR_TITLE=y PR_BRANCH=z "$SCRIPT"
  [ "$status" -ne 0 ]
}

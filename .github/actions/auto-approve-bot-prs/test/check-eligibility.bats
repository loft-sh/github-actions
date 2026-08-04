#!/usr/bin/env bats
# Decision-table coverage for check-eligibility.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/check-eligibility.sh"
DEFAULT='renovate[bot],loft-bot,github-actions[bot],dependabot[bot]'
load assertions

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

@test "update-platform-version- branch → eligible" {
  run_script "$DEFAULT" 'loft-bot' 'anything' 'update-platform-version-4.6.0'; assert_kv eligible true
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

# ---------------------------------------------------------------------------
# Log-injection. This script is step 1 of the composite and runs before any
# trust gate, so PR_TITLE and PR_BRANCH are the widest channel in the action:
# whoever opens the PR picks them, and both are echoed back when the patterns
# do not match. CR terminates a log line for the runner, so a raw one starts a
# NEW line and a line beginning '::' is parsed as a workflow command.

@test "regression: a CR in PR_TITLE cannot forge a workflow command" {
  run_script "$DEFAULT" 'loft-bot' $'feat: x\r::error::FORGED' 'feature/foo'
  [ "$status" -eq 0 ]
  assert_kv eligible false
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
}

@test "regression: a CR in PR_BRANCH cannot forge a workflow command" {
  run_script "$DEFAULT" 'loft-bot' 'feat: x' $'feature/foo\r::error::FORGED'
  [ "$status" -eq 0 ]
  assert_kv eligible false
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
}

@test "regression: a CR in PR_AUTHOR cannot forge a workflow command" {
  # The untrusted-author path echoes the author back before any gate has run.
  run_script "$DEFAULT" $'nobody\r::error::FORGED' 'chore: x' 'x'
  [ "$status" -eq 0 ]
  assert_kv eligible false
  assert_no_match '\r' "$output"
  assert_no_match '(?m)^::error::FORGED' "$output"
}

@test "a missing log lib fails loudly instead of logging unsanitized" {
  # An absent lib/log.sh is a packaging fault. Degrading to unsanitized output
  # would silently reopen the channels above, so the script must die instead —
  # and must not emit its decision. Running a copy with no sibling lib/
  # reproduces it.
  cp "$SCRIPT" "$BATS_TEST_TMPDIR/check-eligibility.sh"
  run env TRUSTED_AUTHORS="$DEFAULT" PR_AUTHOR=loft-bot PR_TITLE='chore: x' \
    PR_BRANCH=x GITHUB_OUTPUT="$GITHUB_OUTPUT" "$BATS_TEST_TMPDIR/check-eligibility.sh"
  [ "$status" -ne 0 ]
  assert_no_match 'eligible=' "$output"
}

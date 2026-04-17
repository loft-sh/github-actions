#!/usr/bin/env bats
# Decision-table coverage for resolve-config.sh.
# Pure env-in, GITHUB_OUTPUT-out — no external CLIs to mock.

SCRIPT="$BATS_TEST_DIRNAME/../src/resolve-config.sh"

setup() {
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

run_script() {
  run env \
    INPUT_PROVIDER="$1" INPUT_EFFORT="$2" INPUT_OUTCOME="$3" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
}

assert_kv() {
  local want="$1=$2" actual
  actual=$(grep "^$1=" "$GITHUB_OUTPUT" | tail -n1)
  [ "$actual" = "$want" ] || {
    echo "want: $want"
    echo "got:  $actual"
    cat "$GITHUB_OUTPUT"
    return 1
  }
}

assert_guidance_contains() {
  local needle="$1"
  grep -q "$needle" "$GITHUB_OUTPUT" || {
    echo "want guidance to contain: $needle"
    cat "$GITHUB_OUTPUT"
    return 1
  }
}

# --- happy path: provider=anthropic × 3 effort levels ------------------------

@test "anthropic:low → model=claude-haiku-4-5, proceed=true" {
  run_script anthropic low pr-comment
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model claude-haiku-4-5
}

@test "anthropic:medium → model=claude-sonnet-4-6, proceed=true" {
  run_script anthropic medium pr-comment
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model claude-sonnet-4-6
}

@test "anthropic:high → model=claude-opus-4-7, proceed=true" {
  run_script anthropic high pr-comment
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model claude-opus-4-7
}

# --- outcome → guidance + tools_suffix --------------------------------------

@test "outcome=pr-comment → empty tools_suffix, guidance mentions SINGLE" {
  run_script anthropic medium pr-comment
  [ "$status" -eq 0 ]
  assert_kv tools_suffix ""
  assert_guidance_contains "SINGLE sticky PR comment"
}

@test "outcome=inline-review → tools_suffix includes inline comment MCP" {
  run_script anthropic medium inline-review
  [ "$status" -eq 0 ]
  assert_kv tools_suffix ",mcp__github_inline_comment__create_inline_comment"
  assert_guidance_contains "inline comments on specific lines"
}

# --- openai stub -------------------------------------------------------------

@test "openai:low → proceed=false, reason mentions not yet implemented" {
  run_script openai low pr-comment
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*not yet implemented' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "openai:medium → proceed=false (stubbed)" {
  run_script openai medium inline-review
  [ "$status" -eq 0 ]
  assert_kv proceed false
}

@test "openai:high → proceed=false (stubbed)" {
  run_script openai high pr-comment
  [ "$status" -eq 0 ]
  assert_kv proceed false
}

# --- input validation --------------------------------------------------------

@test "invalid provider → proceed=false, reason mentions valid list" {
  run_script bedrock medium pr-comment
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*invalid provider' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "invalid effort on anthropic → proceed=false, reason mentions effort" {
  run_script anthropic extreme pr-comment
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*invalid effort' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "invalid effort on openai → proceed=false, reason mentions effort" {
  run_script openai extreme pr-comment
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*invalid effort' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "invalid outcome → proceed=false, reason mentions outcome" {
  run_script anthropic medium label
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*invalid outcome' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

# --- missing required envs ---------------------------------------------------

@test "missing INPUT_PROVIDER fails loudly" {
  run env -u INPUT_PROVIDER \
    INPUT_EFFORT=medium INPUT_OUTCOME=pr-comment \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing INPUT_EFFORT fails loudly" {
  run env -u INPUT_EFFORT \
    INPUT_PROVIDER=anthropic INPUT_OUTCOME=pr-comment \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing INPUT_OUTCOME fails loudly" {
  run env -u INPUT_OUTCOME \
    INPUT_PROVIDER=anthropic INPUT_EFFORT=medium \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

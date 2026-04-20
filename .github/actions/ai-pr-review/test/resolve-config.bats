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
    INPUT_PROVIDER="$1" INPUT_EFFORT="$2" \
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

# --- happy path: provider=anthropic × 3 effort levels ------------------------

@test "anthropic:low → model=claude-haiku-4-5, proceed=true" {
  run_script anthropic low
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model claude-haiku-4-5
}

@test "anthropic:medium → model=claude-sonnet-4-6, proceed=true" {
  run_script anthropic medium
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model claude-sonnet-4-6
}

@test "anthropic:high → model=claude-opus-4-7, proceed=true" {
  run_script anthropic high
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model claude-opus-4-7
}

# --- openai happy path -------------------------------------------------------

@test "openai:low → model=gpt-5.4-mini, proceed=true" {
  run_script openai low
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model gpt-5.4-mini
}

@test "openai:medium → model=gpt-5.3-codex, proceed=true" {
  run_script openai medium
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model gpt-5.3-codex
}

@test "openai:high → model=gpt-5.4, proceed=true" {
  run_script openai high
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv model gpt-5.4
}

# --- input validation --------------------------------------------------------

@test "invalid provider → proceed=false, reason mentions valid list" {
  run_script bedrock medium
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*invalid provider' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "invalid effort on anthropic → proceed=false, reason mentions effort" {
  run_script anthropic extreme
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*invalid effort' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "invalid effort on openai → proceed=false, reason mentions effort" {
  run_script openai extreme
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*invalid effort' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

# --- missing required envs ---------------------------------------------------

@test "missing INPUT_PROVIDER fails loudly" {
  run env -u INPUT_PROVIDER \
    INPUT_EFFORT=medium \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing INPUT_EFFORT fails loudly" {
  run env -u INPUT_EFFORT \
    INPUT_PROVIDER=anthropic \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

#!/usr/bin/env bats
# Decision-table coverage for resolve-config.sh.
# Pure env-in, GITHUB_OUTPUT-out — no external CLIs to mock.

SCRIPT="$BATS_TEST_DIRNAME/../src/resolve-config.sh"

# Non-empty schema value reused across happy-path tests.
SCHEMA='{"type":"object"}'

setup() {
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

run_script() {
  local provider="$1" effort="$2" schema="${3-$SCHEMA}"
  run env \
    INPUT_PROVIDER="$provider" \
    INPUT_EFFORT="$effort" \
    INPUT_OUTPUT_SCHEMA="$schema" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
}

# Session-mode rows: agent set, optional session key and timeout.
run_script_session() {
  local provider="$1" agent="$2" key="$3" timeout="${4-1200}" effort="${5-medium}"
  run env \
    INPUT_PROVIDER="$provider" \
    INPUT_EFFORT="$effort" \
    INPUT_OUTPUT_SCHEMA="$SCHEMA" \
    INPUT_AGENT="$agent" \
    INPUT_ANTHROPIC_SESSION_KEY="$key" \
    INPUT_SESSION_TIMEOUT="$timeout" \
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

# --- schema is the contract --------------------------------------------------

@test "empty output-schema → proceed=false, reason mentions schema" {
  run_script anthropic medium ""
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*output-schema is required' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "whitespace-only output-schema → proceed=false" {
  run_script anthropic medium "   "
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*output-schema is required' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

# --- session mode (agent set) -------------------------------------------------

@test "agent + anthropic + session key → proceed=true, mode=session, model empty" {
  run_script_session anthropic pr-review-lead sk-test-key
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv mode session
  assert_kv model ""
  assert_kv packages "anthropic jsonschema"
}

@test "session key without agent → single mode with a warning naming the wiring" {
  run env \
    INPUT_PROVIDER=anthropic \
    INPUT_EFFORT=medium \
    INPUT_OUTPUT_SCHEMA="$SCHEMA" \
    INPUT_ANTHROPIC_SESSION_KEY=sk-test-key \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv mode single
  echo "$output" | grep -q '::warning::.*anthropic-session-key is set but agent is empty' || {
    echo "$output"; return 1;
  }
}

@test "agent + openai → proceed=false, reason says anthropic-only" {
  run_script_session openai pr-review-lead sk-test-key
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*anthropic-only' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "agent + invalid provider → proceed=false, reason says anthropic-only" {
  run_script_session bedrock pr-review-lead sk-test-key
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*anthropic-only' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "agent + anthropic without session key → proceed=false, reason names the key" {
  run_script_session anthropic pr-review-lead ""
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*anthropic-session-key' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "agent + non-numeric timeout → proceed=false, reason mentions timeout" {
  run_script_session anthropic pr-review-lead sk-test-key never
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*session-timeout-seconds' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

@test "agent + zero timeout → proceed=false" {
  run_script_session anthropic pr-review-lead sk-test-key 0
  [ "$status" -eq 0 ]
  assert_kv proceed false
}

@test "agent ignores effort — invalid effort still proceeds in session mode" {
  run_script_session anthropic pr-review-lead sk-test-key 1200 extreme
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv mode session
}

@test "agent unset → mode=single, packages track the provider" {
  run_script anthropic medium
  [ "$status" -eq 0 ]
  assert_kv proceed true
  assert_kv mode single
  assert_kv packages anthropic
  run_script openai medium
  [ "$status" -eq 0 ]
  assert_kv packages openai
}

@test "empty schema wins over agent — schema skip fires first" {
  run env \
    INPUT_PROVIDER=anthropic \
    INPUT_EFFORT=medium \
    INPUT_OUTPUT_SCHEMA="" \
    INPUT_AGENT=pr-review-lead \
    INPUT_ANTHROPIC_SESSION_KEY=sk-test-key \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_kv proceed false
  grep -q 'reason=.*output-schema is required' "$GITHUB_OUTPUT" || {
    cat "$GITHUB_OUTPUT"; return 1;
  }
}

# --- missing required envs ---------------------------------------------------

@test "missing INPUT_PROVIDER fails loudly" {
  run env -u INPUT_PROVIDER \
    INPUT_EFFORT=medium \
    INPUT_OUTPUT_SCHEMA="$SCHEMA" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing INPUT_EFFORT fails loudly" {
  run env -u INPUT_EFFORT \
    INPUT_PROVIDER=anthropic \
    INPUT_OUTPUT_SCHEMA="$SCHEMA" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing INPUT_OUTPUT_SCHEMA fails loudly" {
  run env -u INPUT_OUTPUT_SCHEMA \
    INPUT_PROVIDER=anthropic \
    INPUT_EFFORT=medium \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

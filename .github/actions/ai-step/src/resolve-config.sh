#!/usr/bin/env bash
# Validate caller inputs and resolve them into the concrete values the
# downstream AI step needs: the execution mode and, in single-call mode,
# the provider-specific model id. All conditional logic for the whole
# action lives here — YAML only dispatches on outputs.
#
# Required env: INPUT_PROVIDER, INPUT_EFFORT, INPUT_OUTPUT_SCHEMA
# Optional env: INPUT_AGENT, INPUT_SESSION_KEY, INPUT_SESSION_TIMEOUT
# Writes to $GITHUB_OUTPUT:
#   proceed=true|false  — whether the AI step should run
#   reason=<string>     — one-line explanation (populated on skip)
#   mode=single|session — session when INPUT_AGENT names a deployed agent
#   model=<string>      — provider-specific model identifier (single mode
#                         only; in session mode the deployed agent owns
#                         its model, so this stays empty)
# Always exits 0 — invalid input degrades to a skip, never hard-fails.
set -euo pipefail

: "${INPUT_PROVIDER:?INPUT_PROVIDER required}"
: "${INPUT_EFFORT:?INPUT_EFFORT required}"
: "${INPUT_OUTPUT_SCHEMA?INPUT_OUTPUT_SCHEMA required}"
INPUT_AGENT="${INPUT_AGENT:-}"
INPUT_SESSION_KEY="${INPUT_SESSION_KEY:-}"
INPUT_SESSION_TIMEOUT="${INPUT_SESSION_TIMEOUT:-1200}"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

skip() {
  local reason="$1"
  echo "::notice::ai-step: $reason"
  emit proceed false
  emit reason  "$reason"
  emit mode    ""
  emit model   ""
  exit 0
}

# schema is the contract of the action — empty schema defeats the point
if [ -z "${INPUT_OUTPUT_SCHEMA// }" ]; then
  skip "output-schema is required — structured output is the contract"
fi

# session mode: agent names a deployed managed agent. Anthropic-only, and
# it needs the workspace-scoped session key — the Messages-API key cannot
# call /v1/sessions. Effort is ignored: the deployed agent owns its model.
if [ -n "${INPUT_AGENT// }" ]; then
  if [ "$INPUT_PROVIDER" != "anthropic" ]; then
    skip "agent mode is anthropic-only — provider '$INPUT_PROVIDER' has no managed-agent counterpart"
  fi
  if [ -z "${INPUT_SESSION_KEY// }" ]; then
    skip "anthropic-session-key is required when agent is set — the Messages-API key cannot call /v1/sessions"
  fi
  case "$INPUT_SESSION_TIMEOUT" in
    ''|*[!0-9]*|0) skip "invalid session-timeout-seconds '$INPUT_SESSION_TIMEOUT' — must be a positive integer" ;;
  esac
  emit proceed true
  emit reason  ""
  emit mode    session
  emit model   ""
  exit 0
fi

# single-call mode: provider + effort → model
case "$INPUT_PROVIDER:$INPUT_EFFORT" in
  anthropic:low)    model='claude-haiku-4-5' ;;
  anthropic:medium) model='claude-sonnet-4-6' ;;
  anthropic:high)   model='claude-opus-4-7' ;;
  anthropic:*)      skip "invalid effort '$INPUT_EFFORT' — valid: low, medium, high" ;;
  openai:low)       model='gpt-5.4-mini' ;;
  openai:medium)    model='gpt-5.3-codex' ;;
  openai:high)      model='gpt-5.4' ;;
  openai:*)         skip "invalid effort '$INPUT_EFFORT' — valid: low, medium, high" ;;
  *)                skip "invalid provider '$INPUT_PROVIDER' — valid: anthropic, openai" ;;
esac

emit proceed true
emit reason  ""
emit mode    single
emit model   "$model"

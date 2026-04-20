#!/usr/bin/env bash
# Validate caller inputs and resolve them into the concrete values the
# downstream AI review step needs: the provider-specific model id. All
# conditional logic for the whole action lives here — YAML only
# dispatches on outputs.
#
# Required env: INPUT_PROVIDER, INPUT_EFFORT
# Writes to $GITHUB_OUTPUT:
#   proceed=true|false  — whether the AI step should run
#   reason=<string>     — one-line explanation (populated on skip)
#   model=<string>      — provider-specific model identifier
# Always exits 0 — invalid input degrades to a skip, never hard-fails.
set -euo pipefail

: "${INPUT_PROVIDER:?INPUT_PROVIDER required}"
: "${INPUT_EFFORT:?INPUT_EFFORT required}"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

skip() {
  local reason="$1"
  echo "::notice::ai-pr-review: $reason"
  emit proceed false
  emit reason  "$reason"
  emit model   ""
  exit 0
}

# provider + effort → model
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
emit model   "$model"

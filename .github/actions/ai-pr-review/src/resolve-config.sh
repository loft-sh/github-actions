#!/usr/bin/env bash
# Validate caller inputs and resolve them into the concrete values the
# downstream AI review step needs: model id, outcome-specific prompt
# guidance, and the extra allowed-tool suffix. All conditional logic
# for the whole action lives here — YAML only dispatches on outputs.
#
# Required env: INPUT_PROVIDER, INPUT_EFFORT, INPUT_OUTCOME
# Writes to $GITHUB_OUTPUT:
#   proceed=true|false     — whether the AI step should run
#   reason=<string>        — one-line explanation (populated on skip)
#   model=<string>         — provider-specific model identifier
#   guidance=<multiline>   — appended to the caller's prompt
#   tools_suffix=<string>  — ",<extra tool>,..." appended to base allowedTools
# Always exits 0 — invalid input degrades to a skip, never hard-fails.
set -euo pipefail

: "${INPUT_PROVIDER:?INPUT_PROVIDER required}"
: "${INPUT_EFFORT:?INPUT_EFFORT required}"
: "${INPUT_OUTCOME:?INPUT_OUTCOME required}"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

emit_multiline() {
  local k="$1" v="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf '%s<<EOF\n' "$k"
      printf '%s\n' "$v"
      printf 'EOF\n'
    } >> "$GITHUB_OUTPUT"
  fi
  printf '%s<<\n%s\n' "$k" "$v"
}

skip() {
  local reason="$1"
  echo "::notice::ai-pr-review: $reason"
  emit proceed false
  emit reason  "$reason"
  emit model   ""
  emit tools_suffix ""
  emit_multiline guidance ""
  exit 0
}

# provider + effort → model
case "$INPUT_PROVIDER:$INPUT_EFFORT" in
  anthropic:low)    model='claude-haiku-4-5' ;;
  anthropic:medium) model='claude-sonnet-4-6' ;;
  anthropic:high)   model='claude-opus-4-7' ;;
  anthropic:*)      skip "invalid effort '$INPUT_EFFORT' — valid: low, medium, high" ;;
  openai:low|openai:medium|openai:high)
                    skip "provider=openai not yet implemented — use provider=anthropic" ;;
  openai:*)         skip "invalid effort '$INPUT_EFFORT' — valid: low, medium, high" ;;
  *)                skip "invalid provider '$INPUT_PROVIDER' — valid: anthropic, openai" ;;
esac

# outcome → prompt guidance + extra allowed tools
case "$INPUT_OUTCOME" in
  pr-comment)
    guidance='Outcome policy: report all findings as a SINGLE sticky PR comment. Do not post inline review comments.'
    tools_suffix=''
    ;;
  inline-review)
    guidance='Outcome policy: post inline comments on specific lines for concrete, actionable findings. A short summary comment is optional.'
    tools_suffix=',mcp__github_inline_comment__create_inline_comment'
    ;;
  *)
    skip "invalid outcome '$INPUT_OUTCOME' — valid: pr-comment, inline-review"
    ;;
esac

emit proceed true
emit reason  ""
emit model   "$model"
emit tools_suffix "$tools_suffix"
emit_multiline guidance "$guidance"

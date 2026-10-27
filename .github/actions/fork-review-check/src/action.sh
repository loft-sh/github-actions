#!/usr/bin/env bash
set -euo pipefail

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s' "${value%"${value##*[![:space:]]}"}"
}

append_lines() {
  local flag=$1
  local values=$2
  local value
  while IFS= read -r value || [ -n "$value" ]; do
    value=$(trim "$value")
    [ -n "$value" ] || continue
    argv+=("$flag" "$value")
  done <<< "$values"
}

argv=(
  "$FORK_REVIEW_CHECK_BIN"
  "$INPUT_MODE"
  -root "$INPUT_ROOT"
  -receipt "$INPUT_RECEIPT"
  "-advisory=$INPUT_ADVISORY"
)

append_lines -dir "$INPUT_DIRS"
append_lines -image "$INPUT_IMAGES"
append_lines -source "$INPUT_SOURCES"
append_lines -signer-workflow "$INPUT_SIGNER_WORKFLOWS"
append_lines -upstream "$INPUT_UPSTREAMS"

if [ -n "$INPUT_AS_OF" ]; then
  argv+=(-as-of "$INPUT_AS_OF")
fi

binary=
while IFS= read -r binary || [ -n "$binary" ]; do
  binary=$(trim "$binary")
  [ -n "$binary" ] || continue
  read -r url sha256 extra <<< "$binary"
  if [ -z "${url:-}" ] || [ -z "${sha256:-}" ] || [ -n "${extra:-}" ]; then
    echo "::error::binaries entries must be <url> <sha256>" >&2
    exit 2
  fi
  argv+=(-url "$url" -sha256 "$sha256")
done <<< "$INPUT_BINARIES"

# A rule failure (exit 1) still writes the receipt, so publish the outputs
# before passing the exit code through.
status=0
"${argv[@]}" || status=$?

if [ -s "$INPUT_RECEIPT" ]; then
  {
    printf 'receipt=%s\n' "$INPUT_RECEIPT"
    printf 'pass=%s\n' "$(jq -r '.pass' "$INPUT_RECEIPT")"
  } >> "$GITHUB_OUTPUT"
fi
exit "$status"

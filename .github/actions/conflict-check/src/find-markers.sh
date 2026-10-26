#!/usr/bin/env bash
# Finds git conflict markers in every tracked text file of the current repository.
set -euo pipefail

report_file="${REPORT_FILE:?REPORT_FILE is required}"
output_file="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# git grep exits 1 when nothing matches; any other non-zero code is a failed scan
status=0
conflicts=$(git grep -I -n -E '^(<<<<<<<|>>>>>>>)( |$)' -- . \
  ':(exclude)vendor/**' ':(exclude)**/vendor/**' ':(exclude)**/node_modules/**') || status=$?
if [ "$status" -gt 1 ]; then
  echo "::error::Conflict marker scan failed (git grep exit code $status)"
  exit "$status"
fi

if [ -z "$conflicts" ]; then
  echo "found=false" >> "$output_file"
  echo "No conflict markers found"
  exit 0
fi

echo "found=true" >> "$output_file"
echo "### Conflict markers found:"
echo "$conflicts"
{
  echo "## Unresolved Merge Conflicts Detected"
  echo ""
  echo "This PR contains unresolved merge conflict markers. Please resolve them before merging."
  echo ""
  echo "### Conflicted Files"
  echo ""
  echo '```'
  echo "$conflicts"
  echo '```'
} > "$report_file"

#!/usr/bin/env bash
set -euo pipefail

# Lists Go functions with a cognitive complexity above THRESHOLD, highest
# first, in the log and the job summary. Exits 0 on findings: report only.
#
# Required environment:
#   THRESHOLD             List functions scoring above this value.
#   GITHUB_STEP_SUMMARY   Standard GitHub Actions job summary file path.
#
# Optional environment:
#   IGNORE                Regexp of file paths to skip. Default: none.
#   SCAN_PATHS            Space-separated files or directories. Default: .
#   GOCOGNIT_BIN          The gocognit binary to run. Default: gocognit.

: "${THRESHOLD:?THRESHOLD is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
IGNORE="${IGNORE:-}"
SCAN_PATHS="${SCAN_PATHS:-.}"
GOCOGNIT_BIN="${GOCOGNIT_BIN:-gocognit}"

# The standard marker for generated Go files (https://go.dev/s/generatedcode).
GENERATED_MARKER='^// Code generated .* DO NOT EDIT\.$'

read -ra PATHS_ARR <<< "${SCAN_PATHS}"

# Filter before gocognit parses anything: its own -ignore only drops results,
# so a parse error in an ignored file would still fail the run.
FILES=()
while IFS= read -r file; do
  FILES+=("${file}")
done < <(
  find "${PATHS_ARR[@]}" -type f -name '*.go' \
    | { if [ -n "${IGNORE}" ]; then grep -Ev -- "${IGNORE}" || true; else cat; fi; } \
    | tr '\n' '\0' \
    | xargs -0 -r grep -LE -- "${GENERATED_MARKER}" || true
)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "::error::no Go files left to scan in '${SCAN_PATHS}' after exclusions"
  exit 1
fi

# gocognit exits 1 both on findings and on errors. Only findings write to stdout.
set +e
REPORT=$("${GOCOGNIT_BIN}" -over "${THRESHOLD}" "${FILES[@]}")
EXIT_CODE=$?
set -e

if [ "${EXIT_CODE}" -ne 0 ] && [ -z "${REPORT}" ]; then
  echo "::error::gocognit failed with exit code ${EXIT_CODE}"
  exit "${EXIT_CODE}"
fi

COUNT=0
if [ -n "${REPORT}" ]; then
  REPORT=$(printf '%s\n' "${REPORT}" | sort -rn)
  COUNT=$(printf '%s\n' "${REPORT}" | wc -l | tr -d ' ')
fi

{
  echo "### ${COUNT} functions with cognitive complexity > ${THRESHOLD}"
  if [ "${COUNT}" -gt 0 ]; then
    echo '```'
    printf '%s\n' "${REPORT}"
    echo '```'
  fi
} | tee -a "${GITHUB_STEP_SUMMARY}"

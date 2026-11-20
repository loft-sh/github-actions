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
#   GOCOGNIT_BIN          Override the gocognit binary (for testing).

: "${THRESHOLD:?THRESHOLD is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
IGNORE="${IGNORE:-}"
SCAN_PATHS="${SCAN_PATHS:-.}"
GOCOGNIT_BIN="${GOCOGNIT_BIN:-gocognit}"

read -ra PATHS_ARR <<< "${SCAN_PATHS}"

# gocognit exits 1 both on findings and on errors. Only findings write to stdout.
set +e
REPORT=$("${GOCOGNIT_BIN}" -over "${THRESHOLD}" -ignore "${IGNORE}" "${PATHS_ARR[@]}")
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

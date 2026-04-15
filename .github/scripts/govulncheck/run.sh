#!/usr/bin/env bash
set -uo pipefail

# Runs govulncheck against the caller's module and emits two GitHub Actions
# step outputs:
#
#   has_vulnerabilities  govulncheck's exit code (0 = clean, non-zero = found)
#   report               Slack-ready report text (only set on non-zero), built
#                        from the tail of govulncheck's output and truncated
#                        to fit Slack's 3000-char block limit.
#
# We capture the exit code ourselves rather than letting `set -e` abort
# because govulncheck returning non-zero is the *expected* outcome on a
# vulnerable module; the workflow then routes it to Slack.
#
# Required environment:
#   GITHUB_OUTPUT         Standard GitHub Actions step output file path.
#
# Optional environment:
#   SCAN_PATHS            Space-separated Go package patterns. Default: ./...
#   TEST_FLAG             "true" to pass -test to govulncheck (include test
#                         files in the scan). Default: "true".
#   GOVULNCHECK_BIN       Override the govulncheck binary (for testing).
#                         Default: govulncheck.
#   REPORT_LIMIT          Max chars of report text. Default: 2800. Slack
#                         block text is capped at 3000; we reserve room for
#                         the "truncated" footer.

SCAN_PATHS="${SCAN_PATHS:-./...}"
TEST_FLAG="${TEST_FLAG:-true}"
GOVULNCHECK_BIN="${GOVULNCHECK_BIN:-govulncheck}"
REPORT_LIMIT="${REPORT_LIMIT:-2800}"

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

ARGS=()
if [ "${TEST_FLAG}" = "true" ]; then
  ARGS+=(-test)
fi

# shellcheck disable=SC2206  # intentional word-splitting of SCAN_PATHS
PATHS_ARR=(${SCAN_PATHS})

echo "Running: ${GOVULNCHECK_BIN} ${ARGS[*]} ${PATHS_ARR[*]}"

# Capture stdout+stderr so Slack gets the full picture. `+e` around the
# invocation only; we need the exit code to decide what to output.
set +e
OUTPUT=$("${GOVULNCHECK_BIN}" "${ARGS[@]}" "${PATHS_ARR[@]}" 2>&1)
EXIT_CODE=$?
set -e

echo "${OUTPUT}"
echo "has_vulnerabilities=${EXIT_CODE}" >> "${GITHUB_OUTPUT}"

if [ "${EXIT_CODE}" -eq 0 ]; then
  echo "No vulnerabilities found"
  exit 0
fi

# Build the report body. When the output exceeds REPORT_LIMIT we keep the
# *tail* rather than the head: govulncheck lists the vulnerability summary
# at the end, so truncating the head is less informative than truncating
# the start of the trace.
if [ "${#OUTPUT}" -gt "${REPORT_LIMIT}" ]; then
  # tail -c takes bytes, which matches ${#OUTPUT}'s char count for ASCII
  # govulncheck output.
  TRUNCATED=$(printf '%s' "${OUTPUT}" | tail -c "${REPORT_LIMIT}")
  REPORT="_...output truncated, see full report in workflow logs_"$'\n\n'"${TRUNCATED}"
else
  REPORT="${OUTPUT}"
fi

{
  echo 'report<<GOVULNCHECK_REPORT_EOF'
  echo "${REPORT}"
  echo 'GOVULNCHECK_REPORT_EOF'
} >> "${GITHUB_OUTPUT}"

# Exit non-zero so the caller's job is marked failed when vulnerabilities
# are found. The Slack step runs via `if: always()` branch logic in the
# workflow, not here.
exit "${EXIT_CODE}"

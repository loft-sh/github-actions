#!/usr/bin/env bash
set -euo pipefail

# Required env vars: GITHUB_OUTPUT
# Optional env vars: REPORT_FILE (defaults to test-reports/report.json)

REPORT_FILE="${REPORT_FILE:-test-reports/report.json}"

if [[ ! -f "$REPORT_FILE" ]]; then
  echo "::warning::JSON report not found at ${REPORT_FILE}"
  if [[ -d "$(dirname "$REPORT_FILE")" ]]; then
    echo "Directory contents:"
    ls -lah "$(dirname "$REPORT_FILE")" || true
  else
    echo "Report directory does not exist"
  fi
  echo "failure-summary=No detailed failure summary available" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "Generating failure summary from JSON report..."

command -v jq >/dev/null || { echo "::error::jq is required but not found"; exit 1; }

# Count as failed: anything not passed, skipped, or pending
STATS=$(jq -r '
  {
    failed: ([.[].SpecReports[] | select(.State | IN("passed", "skipped", "pending") | not)] | length),
    passed: ([.[].SpecReports[] | select(.State == "passed")] | length),
    skipped: ([.[].SpecReports[] | select(.State == "skipped")] | length),
    pending: ([.[].SpecReports[] | select(.State == "pending")] | length),
    total_specs: (.[0].PreRunStats.TotalSpecs // 0),
    specs_to_run: (.[0].PreRunStats.SpecsThatWillRun // 0),
    runtime: ((.[0].RunTime // 0) / 1000000000 | floor)
  }
' "$REPORT_FILE")

FAILED_COUNT=$(echo "$STATS" | jq -r '.failed')
PASSED_COUNT=$(echo "$STATS" | jq -r '.passed')
SKIPPED_COUNT=$(echo "$STATS" | jq -r '.skipped')
PENDING_COUNT=$(echo "$STATS" | jq -r '.pending')
TOTAL_SPECS=$(echo "$STATS" | jq -r '.total_specs')
SPECS_TO_RUN=$(echo "$STATS" | jq -r '.specs_to_run')
RUNTIME=$(echo "$STATS" | jq -r '.runtime')

{
  echo "failure-summary<<EOF"

  echo "*Test Results Summary:*"
  echo "Executed: ${SPECS_TO_RUN}/${TOTAL_SPECS} tests"

  if [[ "$FAILED_COUNT" -gt 0 ]]; then
    echo "Failed: ${FAILED_COUNT}"
    echo "Passed: ${PASSED_COUNT}"
  else
    echo "All tests passed! (${PASSED_COUNT}/${SPECS_TO_RUN})"
  fi

  if [[ "$SKIPPED_COUNT" -gt 0 ]]; then
    echo "Skipped: ${SKIPPED_COUNT}"
  fi
  if [[ "$PENDING_COUNT" -gt 0 ]]; then
    echo "Pending: ${PENDING_COUNT}"
  fi
  echo "Duration: ${RUNTIME}s"

  if [[ "$FAILED_COUNT" -gt 0 ]]; then
    echo ""
    echo "*Failed Tests:*"
    jq -r '[.[].SpecReports[] | select(.State | IN("passed", "skipped", "pending") | not)] |
      .[] |
      "[" + (.State | ascii_upcase) + "] [" + .LeafNodeType + "]" +
      (if .ContainerHierarchyTexts then " " + (.ContainerHierarchyTexts | join(" ")) else "" end) +
      (if .LeafNodeText != "" then " " + .LeafNodeText else "" end) +
      "\n  " + .LeafNodeLocation.FileName + ":" + (.LeafNodeLocation.LineNumber | tostring)' \
      "$REPORT_FILE"
  fi

  echo "EOF"
} >> "$GITHUB_OUTPUT"

echo "Summary generated (Failed: ${FAILED_COUNT}, Passed: ${PASSED_COUNT})"

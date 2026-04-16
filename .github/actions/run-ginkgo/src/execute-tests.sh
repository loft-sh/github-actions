#!/usr/bin/env bash
set -euo pipefail

# Required env vars: TEST_DIR, TIMEOUT, PROCS
# Optional env vars: GINKGO_LABEL, ADDITIONAL_ARGS, ADDITIONAL_GINKGO_FLAGS

WORKSPACE_ROOT="$(pwd)"
REPORTS_DIR="${WORKSPACE_ROOT}/test-reports"
mkdir -p "$REPORTS_DIR"

# Build ginkgo command
GINKGO_ARGS=(
  "run"
  "--timeout=${TIMEOUT}"
  "--procs=${PROCS}"
  "--poll-progress-after=20s"
  "--poll-progress-interval=10s"
  "--github-output"
  "--json-report=${REPORTS_DIR}/report.json"
)

# Append caller-supplied ginkgo flags
if [[ -n "${ADDITIONAL_GINKGO_FLAGS:-}" ]]; then
  read -ra EXTRA_FLAGS <<< "$ADDITIONAL_GINKGO_FLAGS"
  GINKGO_ARGS+=("${EXTRA_FLAGS[@]}")
fi

# Add label filter and recursive search when ginkgo-label is set
if [[ -n "${GINKGO_LABEL:-}" ]]; then
  LABEL_FILTER=$(echo "${GINKGO_LABEL}" | awk '{$1=$1; print}')
  GINKGO_ARGS+=("--label-filter=${LABEL_FILTER}")
  GINKGO_ARGS+=("-r")
fi

echo "Working directory: ${TEST_DIR}"
echo "Command: ginkgo ${GINKGO_ARGS[*]} .${ADDITIONAL_ARGS:+ -- ${ADDITIONAL_ARGS}}"

cd "$TEST_DIR"
# shellcheck disable=SC2086
ginkgo "${GINKGO_ARGS[@]}" . ${ADDITIONAL_ARGS:+-- ${ADDITIONAL_ARGS}}

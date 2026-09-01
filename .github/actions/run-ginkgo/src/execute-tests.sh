#!/usr/bin/env bash
set -euo pipefail

# Required env vars: TEST_DIR, TIMEOUT, PROCS
# Optional env vars: GINKGO_LABEL, ADDITIONAL_ARGS, ADDITIONAL_GINKGO_FLAGS,
#                    GINKGO_FOCUS, FLAKE_ATTEMPTS

WORKSPACE_ROOT="$(pwd)"
REPORTS_DIR="${WORKSPACE_ROOT}/test-reports"
mkdir -p "$REPORTS_DIR"

# Build ginkgo command
GINKGO_ARGS=(
  "run"
  "--timeout=${TIMEOUT}"
  "--procs=${PROCS}"
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

# Set by resolve-rerun-focus.sh to restrict the run to the previous attempt's failures
if [[ -n "${GINKGO_FOCUS:-}" ]]; then
  GINKGO_ARGS+=("--focus=${GINKGO_FOCUS}")
fi

# Retry a spec in-process before calling it failed. Ginkgo reruns only the spec
# that failed, so a suite-wide flake budget costs one spec's runtime, not a whole
# re-run of the job.
#
# Rejects anything that is not an integer >= 1 rather than passing it through:
# ginkgo would reject it too, but only after the whole suite has been set up, so
# a typo here would surface as a failed job minutes later instead of a warning.
# 1 means "no retry" and is ginkgo's own default, so it is not worth an argument.
if [[ -n "${FLAKE_ATTEMPTS:-}" ]]; then
  if [[ "$FLAKE_ATTEMPTS" =~ ^[0-9]+$ ]] && (( FLAKE_ATTEMPTS >= 1 )); then
    (( FLAKE_ATTEMPTS > 1 )) && GINKGO_ARGS+=("--flake-attempts=${FLAKE_ATTEMPTS}")
  else
    echo "::warning::flake-attempts='${FLAKE_ATTEMPTS}' is not an integer >= 1; ignoring it and running without retries"
  fi
fi

echo "Working directory: ${TEST_DIR}"
echo "Command: ginkgo ${GINKGO_ARGS[*]} .${ADDITIONAL_ARGS:+ -- ${ADDITIONAL_ARGS}}"

cd "$TEST_DIR"
# shellcheck disable=SC2086
ginkgo "${GINKGO_ARGS[@]}" . ${ADDITIONAL_ARGS:+-- ${ADDITIONAL_ARGS}}

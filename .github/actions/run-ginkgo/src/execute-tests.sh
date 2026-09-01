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
#
# Leading zeros are stripped before any arithmetic. "08" satisfies ^[0-9]+$ but
# is an invalid octal literal, so (( )) would print its own "value too great for
# base" next to our warning; and forwarding "08" verbatim would fail in ginkgo
# too, since Go's flag package auto-detects the base. Normalizing fixes both.
#
# The length bound comes BEFORE the arithmetic, because bash wraps at signed
# 64-bit while ginkgo's Go int flag rejects out-of-range values - so without it
# the comparison is decided by the overflow. 18446744073709551617 wraps to 1 and
# would silently disable the retries the caller asked for, with no warning;
# 18446744073709551618 wraps to 2 and would forward the original huge value for
# ginkgo to reject. Same guard, and same reason, as numeric_or_default in
# auto-approve-bot-prs.
if [[ -n "${FLAKE_ATTEMPTS:-}" ]]; then
  flake_attempts="${FLAKE_ATTEMPTS#"${FLAKE_ATTEMPTS%%[!0]*}"}"
  [[ -n "$flake_attempts" ]] || flake_attempts=0
  if [[ "$FLAKE_ATTEMPTS" =~ ^[0-9]+$ ]] && (( ${#flake_attempts} <= 9 )) && (( flake_attempts >= 1 )); then
    # `if` rather than `(( … )) && …`, matching the sibling appends above: the
    # AND-list form returns non-zero when the condition is false, which is
    # harmless here only because statements follow it.
    if (( flake_attempts > 1 )); then
      GINKGO_ARGS+=("--flake-attempts=${flake_attempts}")
    fi
  else
    echo "::warning::flake-attempts='${FLAKE_ATTEMPTS}' is not an integer >= 1; ignoring it and running without retries"
  fi
fi

echo "Working directory: ${TEST_DIR}"
echo "Command: ginkgo ${GINKGO_ARGS[*]} .${ADDITIONAL_ARGS:+ -- ${ADDITIONAL_ARGS}}"

cd "$TEST_DIR"
# shellcheck disable=SC2086
ginkgo "${GINKGO_ARGS[@]}" . ${ADDITIONAL_ARGS:+-- ${ADDITIONAL_ARGS}}

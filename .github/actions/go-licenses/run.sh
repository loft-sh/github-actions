#!/usr/bin/env bash
set -euo pipefail

# Runs `go-licenses check` or `go-licenses report` with consistent handling of
# package selection and ignored packages across `go.mod` and `go.work`
# projects. Called from the go-licenses-check / go-licenses-report reusable
# workflows so the branching logic lives in a shellcheck-clean script instead
# of inline YAML.
#
# Usage:
#   run.sh check
#   run.sh report
#
# Required environment variables:
#   PACKAGE_MODE     "all" — pass ./... and --ignore flags to go-licenses.
#                    "go-work" — enumerate workspace modules from go.work and
#                    filter out ignored prefixes at the package list level.
#                    Use this for go-licenses versions < v1.6.0 (no --ignore
#                    flag) and for monorepos whose root does not compile.
#   IGNORED_PACKAGES Comma-separated list of package path prefixes to skip.
#                    In "all" mode they become --ignore flags (matching the
#                    import path prefix). In "go-work" mode they are matched
#                    as substrings against go.work DiskPaths.
#
# Check-mode variables:
#   FAIL_ON_ERROR    "true" (default) or "false". When "false", non-zero exit
#                    codes from go-licenses are logged as a workflow warning
#                    and the step still succeeds — used only as a temporary
#                    escape hatch when upstream go-licenses is broken.
#
# Report-mode variables:
#   TEMPLATE_PATH    Path to the go-licenses .tmpl template (required).
#   OUTPUT_PATH      File to write the rendered report to (required). Any
#                    missing parent directories are created.

SUBCOMMAND="${1:?subcommand is required: check or report}"
PACKAGE_MODE="${PACKAGE_MODE:-all}"
IGNORED_PACKAGES="${IGNORED_PACKAGES:-}"

# Parse IGNORED_PACKAGES into an array of trimmed, non-empty prefixes.
IGNORE=()
if [ -n "${IGNORED_PACKAGES}" ]; then
  IFS=',' read -ra raw_ignore <<< "${IGNORED_PACKAGES}"
  for prefix in "${raw_ignore[@]}"; do
    trimmed="${prefix// /}"
    if [ -n "${trimmed}" ]; then
      IGNORE+=("${trimmed}")
    fi
  done
fi

# Build the go-licenses argument vector based on PACKAGE_MODE.
ARGS=()
case "${PACKAGE_MODE}" in
  all)
    ARGS+=("./...")
    for prefix in ${IGNORE[@]+"${IGNORE[@]}"}; do
      ARGS+=("--ignore" "${prefix}")
    done
    ;;
  go-work)
    mapfile -t PKGS < <(go work edit -json | jq -r '.Use[].DiskPath + "/..."')
    for prefix in ${IGNORE[@]+"${IGNORE[@]}"}; do
      FILTERED=()
      for pkg in ${PKGS[@]+"${PKGS[@]}"}; do
        case "${pkg}" in
          *"${prefix}"*) ;;
          *) FILTERED+=("${pkg}") ;;
        esac
      done
      PKGS=(${FILTERED[@]+"${FILTERED[@]}"})
    done
    if [ "${#PKGS[@]}" -eq 0 ]; then
      echo "::error::no packages to check after filtering IGNORED_PACKAGES" >&2
      exit 1
    fi
    ARGS+=(${PKGS[@]+"${PKGS[@]}"})
    ;;
  *)
    echo "::error::invalid PACKAGE_MODE '${PACKAGE_MODE}' (expected: all, go-work)" >&2
    exit 1
    ;;
esac

case "${SUBCOMMAND}" in
  check)
    FAIL_ON_ERROR="${FAIL_ON_ERROR:-true}"
    if [ "${FAIL_ON_ERROR}" = "true" ]; then
      go-licenses check "${ARGS[@]}"
    else
      if ! go-licenses check "${ARGS[@]}"; then
        echo "::warning::go-licenses check reported errors (ignored because fail-on-error=false)"
      fi
    fi
    ;;
  report)
    : "${TEMPLATE_PATH:?TEMPLATE_PATH env var is required for report}"
    : "${OUTPUT_PATH:?OUTPUT_PATH env var is required for report}"
    mkdir -p "$(dirname "${OUTPUT_PATH}")"
    go-licenses report --template "${TEMPLATE_PATH}" "${ARGS[@]}" > "${OUTPUT_PATH}"
    ;;
  *)
    echo "::error::invalid subcommand '${SUBCOMMAND}' (expected: check, report)" >&2
    exit 1
    ;;
esac

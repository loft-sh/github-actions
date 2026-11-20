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

ROOT=$(pwd -P)
read -ra PATHS_ARR <<< "${SCAN_PATHS}"

# Resolve every scan path physically, so "pkg", "./pkg/." and "$PWD/pkg"
# all yield the same file paths and deduplicate below.
RESOLVED=()
for path in "${PATHS_ARR[@]}"; do
  dir="${path}"
  [ -d "${path}" ] || dir=$(dirname -- "${path}")
  if [ ! -e "${path}" ] || ! abs_dir=$(cd -- "${dir}" && pwd -P); then
    echo "::error::cannot read scan path '${path}'"
    exit 1
  fi
  if [ -d "${path}" ]; then
    RESOLVED+=("${abs_dir}")
  else
    RESOLVED+=("${abs_dir}/$(basename -- "${path}")")
  fi
done

# Outside a pipe, so an unreadable directory fails the step.
if ! FOUND=$(find "${RESOLVED[@]}" -type f -name '*.go'); then
  echo "::error::cannot read every scan path in '${SCAN_PATHS}'"
  exit 1
fi

# Filter before gocognit parses anything: its own -ignore only drops results,
# so a parse error in an ignored file would still fail the run.
CANDIDATES=()
while IFS= read -r file; do
  CANDIDATES+=("${file}")
done < <(
  printf '%s\n' "${FOUND}" \
    | awk -v root="${ROOT}/" 'NF { if (index($0, root) == 1) $0 = substr($0, length(root) + 1); print }' \
    | sort -u \
    | { if [ -n "${IGNORE}" ]; then grep -Ev -- "${IGNORE}" || true; else cat; fi; }
)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "::error::no Go files left to scan in '${SCAN_PATHS}' after exclusions"
  exit 1
fi

# grep exits 1 when no file matches and 2 when a file cannot be read.
set +e
GENERATED=$(grep -lE -- "${GENERATED_MARKER}" "${CANDIDATES[@]}")
GREP_EXIT=$?
set -e
if [ "${GREP_EXIT}" -gt 1 ]; then
  echo "::error::cannot read every Go file in '${SCAN_PATHS}'"
  exit 1
fi

FILES=()
while IFS= read -r file; do
  FILES+=("${file}")
done < <(printf '%s\n' "${CANDIDATES[@]}" | grep -vxF -f <(printf '%s\n' "${GENERATED}") || true)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "::error::no Go files left to scan in '${SCAN_PATHS}' after exclusions"
  exit 1
fi

# gocognit groups files by package only in directory mode, which it needs to
# see recursion across files. So scan a tree of links to the selected files.
TREE=$(mktemp -d)
trap 'rm -rf "${TREE}"' EXIT
last_dir=""
for file in "${FILES[@]}"; do
  dir="."
  [[ "${file}" != */* ]] || dir="${file%/*}"
  if [ "${dir}" != "${last_dir}" ]; then
    mkdir -p "${TREE}/${dir}"
    last_dir="${dir}"
  fi
  target="${file}"
  [[ "${file}" == /* ]] || target="${ROOT}/${file}"
  ln -s "${target}" "${TREE}/${file}"
done

# gocognit exits 1 both on findings and on errors. Only findings write to stdout.
# -test leaves the choice of test files to IGNORE.
set +e
REPORT=$("${GOCOGNIT_BIN}" -over "${THRESHOLD}" -test "${TREE}")
EXIT_CODE=$?
set -e

if [ "${EXIT_CODE}" -ne 0 ] && [ -z "${REPORT}" ]; then
  echo "::error::gocognit failed with exit code ${EXIT_CODE}"
  exit "${EXIT_CODE}"
fi

REPORT="${REPORT//"${TREE}/"/}"

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

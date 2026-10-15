#!/usr/bin/env bash
# Map action inputs to sweep.py flags. The exit code passes through unchanged:
# 0 clean, 1 indicator found, 2 sweep incomplete.
set -euo pipefail

: "${INPUT_OWNERS:?owners is required}"
: "${SWEEP_PY:?SWEEP_PY is required}"

read -r -a owners <<< "${INPUT_OWNERS//$'\n'/ }"
args=(--owners "${owners[@]}"
  --audit-days "${INPUT_AUDIT_DAYS:-8}"
  --jobs "${INPUT_JOBS:-8}"
  --report "${INPUT_REPORT_PATH:-ioc-sweep-report.json}")
[[ -n "${INPUT_IOCS_FILE:-}" ]] && args+=(--iocs "$INPUT_IOCS_FILE")
[[ -n "${INPUT_HISTORY_SINCE:-}" ]] && args+=(--since "$INPUT_HISTORY_SINCE")

exec python3 "$SWEEP_PY" "${args[@]}"

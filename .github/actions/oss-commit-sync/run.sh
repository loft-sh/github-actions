#!/usr/bin/env bash
set -euo pipefail

# Entry point for the composite action: dispatch on DIRECTION.
case "${DIRECTION:?DIRECTION is required (export|import|health)}" in
  export) exec "$(dirname "${BASH_SOURCE[0]}")/export.sh" ;;
  import) exec "$(dirname "${BASH_SOURCE[0]}")/import.sh" ;;
  health) exec "$(dirname "${BASH_SOURCE[0]}")/health.sh" ;;
  *)
    echo "::error::unknown DIRECTION '${DIRECTION}' (want export, import, or health)"
    exit 1
    ;;
esac

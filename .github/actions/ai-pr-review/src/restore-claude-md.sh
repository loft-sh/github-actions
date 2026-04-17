#!/usr/bin/env bash
# Restore CLAUDE.md from the PR base branch before Claude runs.
# Prevents prompt injection: a malicious PR head could put instructions
# in CLAUDE.md that override the caller's review prompt.
#
# Required env: BASE_REF
set -euo pipefail

: "${BASE_REF:?BASE_REF required}"

git show "origin/${BASE_REF}:CLAUDE.md" > CLAUDE.md 2>/dev/null || rm -f CLAUDE.md

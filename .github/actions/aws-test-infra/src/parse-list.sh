#!/usr/bin/env bash
# Turn a newline-separated list on stdin into repeatable CLI flags.
#
# Usage: parse-list.sh <flag-name> < list
#
# Prints one "<flag-name>=<value>" per non-empty line, stripping surrounding
# whitespace and any trailing CR (CRLF-origin YAML). Values may contain spaces,
# '=', or ':'. Used by the s3-stage step to build the -upload / -presign flags
# for the aws-test-infra binary; kept as a script (not inline YAML) so it can be
# unit-tested with bats.
set -euo pipefail

flag="${1:?flag name required (e.g. -upload)}"

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"                    # strip trailing CR (CRLF input)
  line="${line#"${line%%[![:space:]]*}"}" # trim leading whitespace
  line="${line%"${line##*[![:space:]]}"}" # trim trailing whitespace
  [ -z "$line" ] && continue
  printf '%s=%s\n' "$flag" "$line"
done

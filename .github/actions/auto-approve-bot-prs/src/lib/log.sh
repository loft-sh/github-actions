#!/usr/bin/env bash
# Log-safety helpers shared by every script in this action. Sourced, never
# executed — so it is deliberately not +x and defines functions only.
#
# EVERY externally-controlled string that reaches an `echo` in this action must
# go through here. The channels that qualify are all hostile:
#   - gh's stderr/stdout (GitHub-controlled), on both the CI poll and the merge,
#   - check-run `.name` / commit-status `.context`, written by whoever posted the
#     check on the head SHA. GitHub documents no character restriction on them,
#     so they are the *widest* channel.
#   - the authenticated login from `gh api user`. The API answers in JSON, and a
#     `\r` escape inside a JSON string decodes to a real CR through `jq -r`, so
#     "logins cannot contain control characters" does not close this one.
#   - caller-supplied inputs that are echoed back on rejection (merge-method),
#     which a calling workflow can set to anything.
#
# What sanitize_for_log defends against:
#   - CR as well as LF terminates a log line for the runner, so a raw one splits
#     the output into a NEW line, and a line beginning `::` is parsed as a
#     workflow command. An attacker naming a check `x<CR>::error::…` would
#     otherwise forge one. Collapse both, plus TAB, to spaces.
#   - Other separators the runner or a terminal may treat as breaks (VT, FF, NUL,
#     DEL, and via the non-ASCII strip: NEL, U+2028, U+2029) are removed.
#   - Non-ASCII is dropped rather than byte-truncated, so the length cap cannot
#     split a UTF-8 sequence mid-character.
#   - `%` is the workflow-command escape introducer, so a literal `%0A`/`%25`
#     would otherwise be decoded into the annotation. Escaped AFTER the first
#     cut so that cut cannot bisect an escape we just wrote; a second cut then
#     bounds the real emitted length, and the trailing-partial strip removes a
#     `%` or `%2` left dangling by it.
#   - LC_ALL is pinned on both `tr` calls so an inherited locale cannot defeat
#     the class matching.
#
# Never fails: a subshell abort here would kill the caller under `set -e` before
# it could emit its output contract (ci_green / proceed), which is the same
# violation as a fatal mktemp.

# sanitize_for_log — stdin to a single safe log line on stdout.
#
# Optional arg: max emitted characters (default 300). Escaping runs BEFORE the
# truncation so the cap bounds the line that is actually emitted rather than a
# pre-escape length that can then triple; the trailing-partial strip removes a
# `%` or `%2` the cut may leave dangling. Truncation is marked, because a name
# severed mid-word reads as a corrupted check name rather than as elision.
sanitize_for_log() {
  local max="${1:-300}"
  { LC_ALL=C tr '\n\r\t' '   ' \
      | LC_ALL=C tr -cd '\040-\176' \
      | sed 's/%/%25/g' \
      | LC_ALL=C awk -v m="$max" '{ if (length($0) > m) printf "%s... (truncated)\n", substr($0, 1, m); else print }' \
      | sed 's/%2\{0,1\}$//'; } 2>/dev/null || true
}

# safe <string> [max] — sanitize a value for interpolation into a log line.
safe() {
  printf '%s' "${1:-}" | sanitize_for_log "${2:-300}"
}

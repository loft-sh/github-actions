#!/usr/bin/env bash
# Pure helpers for the comment-triggered-check action.
#
# Everything here is network-free and side-effect free so the whole decision
# surface is testable with bats. The scripts that talk to the API (start.sh,
# finish.sh) source this file and keep only the I/O.

# trim <string> — strip leading and trailing whitespace. Bash-only, no
# subprocess, so it is safe to call in a loop.
trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# parse_command <command> <comment-body>
# Prints the argument string when the comment's FIRST line is the command.
# Returns 1 otherwise.
#
# First line only, deliberately. Quoting a command while discussing it ("we
# should run /test-e2e snapshots here") must not fire a run, and that is the common
# case in a busy thread. It also keeps the trigger unambiguous when a comment
# ends with a bot signature.
parse_command() {
  local command="${1-}" body="${2-}" first
  first="${body%%$'\n'*}"
  first="${first%$'\r'}"
  first="$(trim "$first")"

  if [[ "$first" != "$command" && "$first" != "$command "* && "$first" != "$command"$'\t'* ]]; then
    return 1
  fi

  trim "${first#"$command"}"
}

# normalize_filter <string> — collapse internal whitespace runs to one space and
# trim. A Ginkgo label filter is whitespace-insensitive, so this makes the
# concurrency key and the check name stable across "a && b" and "a &&  b".
normalize_filter() {
  local s
  s="$(printf '%s' "${1-}" | LC_ALL=C tr -s '[:space:]' ' ')"
  trim "$s"
}

# sanitize_slug <string> [max-length]
# Lowercase, non-alphanumerics collapsed to single dashes, trimmed, truncated.
# Used for the concurrency key, which is interpolated into YAML and must not
# carry quotes, braces or newlines from user input.
sanitize_slug() {
  local s="${1-}" max="${2:-60}"
  s="$(printf '%s' "$s" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//')"
  printf '%s' "${s:0:$max}"
}

# short_digest <string> — 8 stable hex-ish characters. cksum is in coreutils and
# in the BSD userland, unlike sha256sum/shasum which differ between the runner
# and a developer's Mac.
short_digest() {
  printf '%s' "${1-}" | cksum | awk '{ printf "%08x", $1 }'
}

# concurrency_key <filter> [max-slug-length]
# A key that is safe to interpolate into a concurrency group AND unique per
# filter. The slug alone is not: it drops every non-alphanumeric character, so
# `snapshots && aws` and `snapshots || aws` both reduce to `snapshots-aws`.
# Those are opposite requests, and sharing a group would make one cancel the
# other. The digest is taken over the normalized filter, so it survives both the
# punctuation loss and the truncation.
concurrency_key() {
  local filter normalized slug
  normalized="$(normalize_filter "${1-}")"
  slug="$(sanitize_slug "$normalized" "${2:-40}")"
  printf '%s-%s' "${slug:-filter}" "$(short_digest "$normalized")"
}

# check_name <prefix> <filter> [max-length]
# The display name of the check-run, derived from user input, so it is
# sanitized and bounded. When the filter is too long to show in full the name
# carries a digest of the whole filter, because this name is also the dedupe
# key: two different long filters that truncated to the same text would
# otherwise be treated as the same in-flight run.
check_name() {
  local prefix="${1-}" filter="${2-}" max="${3:-60}" cleaned
  cleaned="$(printf '%s' "$(normalize_filter "$filter")" | LC_ALL=C tr -cd '\040-\176')"

  if [[ "${#cleaned}" -le "$max" ]]; then
    printf '%s: %s' "$prefix" "$cleaned"
    return 0
  fi

  printf '%s: %s... (%s)' "$prefix" "${cleaned:0:$max}" "$(short_digest "$cleaned")"
}

# CONCLUSIONS_FROM_REPORT — the conclusions the suite is allowed to declare for
# itself. Deliberately narrower than the Checks API set: action_required and
# skipped are not outcomes a test run should ever report, and accepting them
# would let an unexpected value through as something that reads acceptable.
CONCLUSIONS_FROM_REPORT="success failure neutral cancelled timed_out"

# resolve_conclusion <report-conclusion> <build-result> <suite-result>
# The fail-closed outcome matrix. See the design doc, DEVOPS-1333.
#
#   explicit report conclusion    -> use it. THE ONLY PATH TO neutral.
#   suite or build was cancelled  -> cancelled
#   anything else                 -> failure
#
# The two mappings this deliberately does NOT have are the point:
#
#   "no output but the job ran" must not become cancelled, because that state
#   also covers a failed checkout, setup, artifact download or cloud login, and
#   cancelled is not cheap. wait-for-ci.sh holds a cancelled check waiting for a
#   replacement and then refuses approval, so a mis-mapped cancelled stalls
#   auto-approve instead of failing cleanly.
#
#   "suite skipped but build succeeded" must not become neutral, because
#   neutral is an acceptable verdict and an unexplained skip is not an
#   acceptable outcome. Once a check-run exists, anything we cannot explain is
#   a failure.
resolve_conclusion() {
  local report="${1-}" build_result="${2-}" suite_result="${3-}"

  if [[ -n "$report" ]]; then
    # Exact match, word by word. Substring membership passes any adjacent slice
    # of the list, so "success failure" reaches the Checks API and 400s.
    if printf '%s' "$CONCLUSIONS_FROM_REPORT" | tr ' ' '\n' | grep -qxF -- "$report"; then
      printf '%s' "$report"
      return 0
    fi
    echo "::warning::suite reported an unrecognised conclusion '${report}'; failing closed" >&2
    printf 'failure'
    return 0
  fi

  # A cancelled build or suite is an explained outcome, so it does not fall
  # through to the catch-all. Cancelling the run leaves build=cancelled and
  # suite=skipped, which would otherwise read as a red check for something the
  # author did on purpose.
  if [[ "$suite_result" == "cancelled" || "$build_result" == "cancelled" ]]; then
    printf 'cancelled'
    return 0
  fi

  printf 'failure'
}

# AUTHORIZED_ASSOCIATIONS — comment author_association values that imply access
# to the repository. CONTRIBUTOR means "has landed a PR here", not "can run
# things here", so it is not on the list.
AUTHORIZED_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

# is_authorized_association <association>
# Whether the commenter may run the command, decided from the event payload
# rather than a collaborator API call. Coarser than that endpoint, since a
# read-only collaborator also reads as COLLABORATOR, and that trade is
# deliberate: the command is same-repo only, so the cost of the coarseness is
# runner time rather than access. Empty or unrecognised is always a no.
is_authorized_association() {
  local association="${1-}"
  [[ -n "$association" ]] || return 1
  [[ " $AUTHORIZED_ASSOCIATIONS " == *" $association "* ]]
}

# emit <name> <value> — write a step output and echo it for the log.
emit() {
  printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
  printf '%s=%s\n' "$1" "$2"
}

#!/usr/bin/env bats
# Tests for the pure decision surface of the comment-triggered-check action.
#
# Everything in lib.sh is network-free, so the parsing, sanitizing and outcome
# rules are covered here rather than only in a live smoke run. The scripts that
# call the API keep no decisions of their own beyond wiring these.

LIB="$BATS_TEST_DIRNAME/../src/lib.sh"

setup() {
  # shellcheck source=.github/actions/comment-triggered-check/src/lib.sh
  source "$LIB"
}

# --- parse_command -----------------------------------------------------------

@test "parse_command: bare command matches with empty args" {
  run parse_command "/test" "/test"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "parse_command: command with a filter returns the filter" {
  run parse_command "/test" "/test snapshots"
  [ "$status" -eq 0 ]
  [ "$output" = "snapshots" ]
}

@test "parse_command: only the first line is considered" {
  run parse_command "/test" "$(printf '/test snapshots\nplease ignore this')"
  [ "$status" -eq 0 ]
  [ "$output" = "snapshots" ]
}

@test "parse_command: a quoted command later in the comment does not fire" {
  run parse_command "/test" "$(printf 'we should run\n/test snapshots\nafter this lands')"
  [ "$status" -ne 0 ]
}

@test "parse_command: a command mid-line does not fire" {
  run parse_command "/test" "maybe /test snapshots would help"
  [ "$status" -ne 0 ]
}

@test "parse_command: a longer command word is not a prefix match" {
  run parse_command "/test" "/testing something"
  [ "$status" -ne 0 ]
}

@test "parse_command: leading whitespace and CRLF are tolerated" {
  run parse_command "/test" "$(printf '   /test  snapshots  \r\nrest')"
  [ "$status" -eq 0 ]
  [ "$output" = "snapshots" ]
}

@test "parse_command: an unrelated comment does not fire" {
  run parse_command "/test" "LGTM, nice work"
  [ "$status" -ne 0 ]
}

# --- parse_request -----------------------------------------------------------

@test "parse_request: a label-only request stays unchanged" {
  parse_request "  snapshots   &&  aws  " "true"
  [ "$REQUEST_FILTER" = "snapshots && aws" ]
  [ "$REQUEST_FOCUS" = "" ]
  [ "$REQUEST_ERROR" = "" ]
}

@test "parse_request: strips one matching quote pair from focus" {
  parse_request 'snapshots --focus "creates snapshots"' "true"
  [ "$REQUEST_FILTER" = "snapshots" ]
  [ "$REQUEST_FOCUS" = "creates snapshots" ]
  [ "$REQUEST_ERROR" = "" ]
}

@test "parse_request: accepts the unquoted remainder as focus" {
  parse_request 'snapshots --focus creates snapshots' "true"
  [ "$REQUEST_FILTER" = "snapshots" ]
  [ "$REQUEST_FOCUS" = "creates snapshots" ]
  [ "$REQUEST_ERROR" = "" ]
}

@test "parse_request: accepts tabs around the focus marker" {
  parse_request $'snapshots\t--focus\tcreates snapshots' "true"
  [ "$REQUEST_FILTER" = "snapshots" ]
  [ "$REQUEST_FOCUS" = "creates snapshots" ]
  [ "$REQUEST_ERROR" = "" ]
}

@test "parse_request: focus may itself contain the focus flag text" {
  parse_request 'snapshots --focus "supports --focus in commands"' "true"
  [ "$REQUEST_FILTER" = "snapshots" ]
  [ "$REQUEST_FOCUS" = "supports --focus in commands" ]
  [ "$REQUEST_ERROR" = "" ]
}

@test "parse_request: preserves regex whitespace and parentheses in focus" {
  parse_request 'snapshots --focus "^creates  snapshots \\(HA\\)$"' "true"
  [ "$REQUEST_FILTER" = "snapshots" ]
  [ "$REQUEST_FOCUS" = '^creates  snapshots \\(HA\\)$' ]
  [ "$REQUEST_ERROR" = "" ]
}

@test "parse_request: shell and workflow-command syntax stays literal" {
  parse_request 'snapshots --focus "$(touch pwned);`id`;%0A::error::boom"' "true"
  [ "$REQUEST_FILTER" = "snapshots" ]
  [ "$REQUEST_FOCUS" = '$(touch pwned);`id`;%0A::error::boom' ]
  [ "$REQUEST_ERROR" = "" ]
}

@test "parse_request: rejects a focus flag with no value" {
  parse_request 'snapshots --focus' "true"
  [ "$REQUEST_ERROR" = "malformed-focus" ]
}

@test "parse_request: rejects an empty quoted focus" {
  parse_request 'snapshots --focus ""' "true"
  [ "$REQUEST_ERROR" = "malformed-focus" ]
}

@test "parse_request: a focus without a label still reports an empty filter" {
  parse_request '--focus "creates snapshots"' "true"
  [ "$REQUEST_FILTER" = "" ]
  [ "$REQUEST_FOCUS" = "creates snapshots" ]
  [ "$REQUEST_ERROR" = "" ]
}

@test "parse_request: focus parsing is opt-in for existing consumers" {
  parse_request 'snapshots --focus "creates snapshots"' ""
  [ "$REQUEST_FILTER" = 'snapshots --focus "creates snapshots"' ]
  [ "$REQUEST_FOCUS" = "" ]
  [ "$REQUEST_ERROR" = "" ]
}

# --- normalize_filter --------------------------------------------------------

@test "normalize_filter: collapses whitespace runs and trims" {
  run normalize_filter "  db-datasource   &&    aws  "
  [ "$output" = "db-datasource && aws" ]
}

@test "normalize_filter: a real category label survives intact" {
  run normalize_filter 'containsAny {aws, azure}'
  [ "$output" = "containsAny {aws, azure}" ]
}

# --- filter_is_balanced ------------------------------------------------------

@test "filter_is_balanced: a plain filter is balanced" {
  run filter_is_balanced "snapshots || embedded-etcd"
  [ "$status" -eq 0 ]
}

@test "filter_is_balanced: matched groups are balanced" {
  run filter_is_balanced "(snapshots || cli) && ha"
  [ "$status" -eq 0 ]
}

@test "filter_is_balanced: a category label with braces is balanced" {
  run filter_is_balanced "hyperscaler: containsAny {aws, gcp}"
  [ "$status" -eq 0 ]
}

@test "filter_is_balanced: empty is balanced" {
  run filter_is_balanced ""
  [ "$status" -eq 0 ]
}

@test "filter_is_balanced: rejects the guard escape" {
  run filter_is_balanced "snapshots) || non-default || (snapshots"
  [ "$status" -eq 1 ]
}

@test "filter_is_balanced: rejects a close before any open" {
  run filter_is_balanced "snapshots)"
  [ "$status" -eq 1 ]
}

@test "filter_is_balanced: rejects an unclosed open" {
  run filter_is_balanced "((snapshots"
  [ "$status" -eq 1 ]
}

# --- sanitize_slug -----------------------------------------------------------

@test "sanitize_slug: braces, spaces and punctuation become single dashes" {
  run sanitize_slug 'containsAny {aws, azure}'
  [ "$output" = "containsany-aws-azure" ]
}

@test "sanitize_slug: no leading or trailing dashes" {
  run sanitize_slug '  && snapshots &&  '
  [ "$output" = "snapshots" ]
}

@test "sanitize_slug: truncates to the requested length" {
  run sanitize_slug "aaaaaaaaaaaaaaaaaaaa" 8
  [ "$output" = "aaaaaaaa" ]
}

@test "sanitize_slug: a shell metacharacter payload is reduced to a slug" {
  run sanitize_slug '$(rm -rf /) && `id`'
  [[ "$output" != *'$'* ]]
  [[ "$output" != *'`'* ]]
  [[ "$output" != *'('* ]]
}

# --- concurrency_key ---------------------------------------------------------

@test "concurrency_key: opposite operators do not share a key" {
  a="$(concurrency_key 'snapshots && aws')"
  b="$(concurrency_key 'snapshots || aws')"
  [ "$a" != "$b" ]
}

@test "concurrency_key: the slug alone would have collided" {
  # Pins the reason the digest exists, so removing it fails loudly.
  [ "$(sanitize_slug 'snapshots && aws')" = "$(sanitize_slug 'snapshots || aws')" ]
}

@test "concurrency_key: negation is distinguished from plain" {
  a="$(concurrency_key 'snapshots')"
  b="$(concurrency_key '!snapshots')"
  [ "$a" != "$b" ]
}

@test "concurrency_key: whitespace-only differences share a key" {
  a="$(concurrency_key 'snapshots   &&  aws')"
  b="$(concurrency_key 'snapshots && aws')"
  [ "$a" = "$b" ]
}

@test "concurrency_key: two long filters differing past truncation do not collide" {
  base="$(printf 'a%.0s' {1..60})"
  a="$(concurrency_key "${base}alpha")"
  b="$(concurrency_key "${base}omega")"
  [ "$a" != "$b" ]
}

@test "concurrency_key: is safe to interpolate" {
  run concurrency_key 'containsAny {aws, azure} && !non-default'
  [[ "$output" =~ ^[a-z0-9-]+$ ]]
}

@test "concurrency_key: a punctuation-only filter still yields a usable key" {
  run concurrency_key '&& ||'
  [[ "$output" =~ ^[a-z0-9-]+$ ]]
  [ -n "$output" ]
}

@test "concurrency_key: is stable across calls" {
  a="$(concurrency_key 'snapshots && aws')"
  b="$(concurrency_key 'snapshots && aws')"
  [ "$a" = "$b" ]
}

@test "request_identity: two focuses under one label do not collide" {
  a="$(request_identity 'snapshots' 'creates snapshots')"
  b="$(request_identity 'snapshots' 'deletes snapshots')"
  [ "$(concurrency_key "$a")" != "$(concurrency_key "$b")" ]
}

@test "request_identity: focus whitespace remains significant" {
  a="$(request_identity 'snapshots' 'creates snapshots')"
  b="$(request_identity 'snapshots' 'creates  snapshots')"
  [ "$(concurrency_key "$a")" != "$(concurrency_key "$b")" ]
}

@test "request_identity: a typeable label cannot impersonate a focused request" {
  focused="$(request_identity 'snapshots' 'creates snapshots')"
  label="$(request_identity 'snapshots focus-digest-7b53924f' '')"
  [ "$(concurrency_key "$focused")" != "$(concurrency_key "$label")" ]
}

# --- check_name --------------------------------------------------------------

@test "check_name: short filter is shown in full" {
  run check_name "e2e" "snapshots"
  [ "$output" = "e2e: snapshots" ]
}

@test "check_name: preserves meaningful focus whitespace" {
  run check_name "e2e" 'snapshots --focus "creates  snapshots"' 60
  [ "$output" = 'e2e: snapshots --focus "creates  snapshots"' ]
}

@test "check_name: control characters are stripped" {
  run check_name "e2e" "$(printf 'snap\x01shots')"
  [ "$output" = "e2e: snapshots" ]
}

@test "check_name: a long filter is truncated and digested" {
  long="$(printf 'a%.0s' {1..120})"
  run check_name "e2e" "$long"
  [[ "$output" == "e2e: aaa"* ]]
  [[ "$output" == *"... ("* ]]
  [ "${#output}" -lt 90 ]
}

@test "check_name: two different long filters do not collide" {
  a="$(printf 'a%.0s' {1..80})x"
  b="$(printf 'a%.0s' {1..80})y"
  run check_name "e2e" "$a"
  first="$output"
  run check_name "e2e" "$b"
  [ "$first" != "$output" ]
}

# --- resolve_conclusion ------------------------------------------------------

@test "resolve_conclusion: an explicit report conclusion wins" {
  run resolve_conclusion "success" "success" "success"
  [ "$output" = "success" ]
}

@test "resolve_conclusion: neutral is reachable only from the report" {
  run resolve_conclusion "neutral" "success" "success"
  [ "$output" = "neutral" ]
}

@test "resolve_conclusion: a skipped suite after a good build is a failure, not neutral" {
  run resolve_conclusion "" "success" "skipped"
  [ "$output" = "failure" ]
}

@test "resolve_conclusion: an empty report after the job ran is a failure, not cancelled" {
  run resolve_conclusion "" "success" "failure"
  [ "$output" = "failure" ]
}

@test "resolve_conclusion: a build failure is a failure" {
  run resolve_conclusion "" "failure" "skipped"
  [ "$output" = "failure" ]
}

@test "resolve_conclusion: cancelling the whole run reads as cancelled, not failure" {
  run resolve_conclusion "" "cancelled" "skipped"
  [ "$output" = "cancelled" ]
}

@test "resolve_conclusion: a genuinely cancelled suite is cancelled" {
  run resolve_conclusion "" "success" "cancelled"
  [ "$output" = "cancelled" ]
}

# The warning names the rejected value, so it has to be kept out of the
# assertion: `run` merges stderr into $output. Capture stdout on its own.
@test "resolve_conclusion: an unrecognised report conclusion fails closed" {
  result="$(resolve_conclusion "action_required" "success" "success" 2>/dev/null)"
  [ "$result" = "failure" ]
}

# The list is checked word by word. Substring membership passed any adjacent
# slice of it, and the value went to the Checks API verbatim.
@test "resolve_conclusion: a multi-token value is not a member of the list" {
  result="$(resolve_conclusion "success failure" "success" "success" 2>/dev/null)"
  [ "$result" = "failure" ]
}

@test "resolve_conclusion: a trailing slice of the list is rejected too" {
  result="$(resolve_conclusion "neutral cancelled" "success" "success" 2>/dev/null)"
  [ "$result" = "failure" ]
}

@test "resolve_conclusion: rejecting a bad value warns rather than passing it through" {
  warning="$(resolve_conclusion "action_required" "success" "success" 2>&1 >/dev/null)"
  [[ "$warning" == *"::warning::"* ]]
  [[ "$warning" == *"action_required"* ]]
}

@test "resolve_conclusion: skipped is not accepted from the report" {
  result="$(resolve_conclusion "skipped" "success" "success" 2>/dev/null)"
  [ "$result" = "failure" ]
}

@test "resolve_conclusion: every unmapped combination is a failure" {
  for build in success failure skipped; do
    for suite in success failure skipped; do
      run resolve_conclusion "" "$build" "$suite"
      [ "$output" = "failure" ]
    done
  done
}

# --- is_authorized_association -----------------------------------------------

@test "is_authorized_association: an owner may run it" {
  run is_authorized_association "OWNER"
  [ "$status" -eq 0 ]
}

@test "is_authorized_association: an org member may run it" {
  run is_authorized_association "MEMBER"
  [ "$status" -eq 0 ]
}

@test "is_authorized_association: a collaborator may run it" {
  run is_authorized_association "COLLABORATOR"
  [ "$status" -eq 0 ]
}

@test "is_authorized_association: a past contributor may not" {
  run is_authorized_association "CONTRIBUTOR"
  [ "$status" -ne 0 ]
}

@test "is_authorized_association: an outsider may not" {
  run is_authorized_association "NONE"
  [ "$status" -ne 0 ]
}

@test "is_authorized_association: a first-time contributor may not" {
  run is_authorized_association "FIRST_TIME_CONTRIBUTOR"
  [ "$status" -ne 0 ]
}

@test "is_authorized_association: empty is a no, not a default yes" {
  run is_authorized_association ""
  [ "$status" -ne 0 ]
}

@test "is_authorized_association: an unrecognised value is a no" {
  run is_authorized_association "MANNEQUIN"
  [ "$status" -ne 0 ]
}

@test "is_authorized_association: matching is exact, not substring" {
  run is_authorized_association "OWNE"
  [ "$status" -ne 0 ]
}

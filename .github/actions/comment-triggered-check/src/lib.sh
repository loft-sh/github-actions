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

# REPEAT_MAX and RUNS_MAX bound --repeat and --runs, so a typo cannot start a
# run for hours or fan out across dozens of runners.
REPEAT_MAX=10
RUNS_MAX=5

# take_count_option <flag> <string>
# Removes every standalone `<flag> <value>` pair from string. Sets OPTION_REST
# to the remaining words, OPTION_FOUND, OPTION_VALUE, and OPTION_ERROR (missing
# or duplicate). Rejoining words on single spaces is lossless for a label filter.
# shellcheck disable=SC2034 # OPTION_* are the function's outputs for callers.
take_count_option() {
  local flag="${1-}" word expect_value=false
  local -a words=() kept=()
  read -r -a words <<< "${2-}"
  OPTION_FOUND=false
  OPTION_VALUE=""
  OPTION_ERROR=""
  for word in ${words[@]+"${words[@]}"}; do
    if [[ "$expect_value" == "true" ]]; then
      OPTION_VALUE="$word"
      expect_value=false
      continue
    fi
    if [[ "$word" == "$flag" ]]; then
      [[ "$OPTION_FOUND" == "true" ]] && OPTION_ERROR="duplicate"
      OPTION_FOUND=true
      expect_value=true
      continue
    fi
    kept+=("$word")
  done
  [[ "$expect_value" == "true" ]] && OPTION_ERROR="missing"
  OPTION_REST="${kept[*]-}"
}

# count_error <value> <max> — prints malformed or out-of-range, nothing when the
# value is a whole number from 1 to max.
count_error() {
  local value="${1-}" max="${2-}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf 'malformed'
  elif (( ${#value} > ${#max} )) || (( 10#$value < 1 || 10#$value > max )); then
    printf 'out-of-range'
  fi
}

# parse_request <arguments> <parse-focus> <parse-target> <allowed-targets> [parse-repeat] [parse-runs]
# Splits an optional trailing `--focus <regex>` and an optional
# `--target <value>` immediately before it from the required label filter. The
# focus is the whole remainder: it is never evaluated as shell syntax, and one
# matching outer quote pair is removed only for comment readability. Targets
# are single tokens matched exactly against the whitespace-separated allowlist.
# `--repeat N` and `--runs N` may stand anywhere before the focus, and only one
# of them at a time.
# Results are returned in globals because command substitution would run this
# function in a subshell and lose them.
# shellcheck disable=SC2034 # REQUEST_* are the function's outputs for callers.
parse_request() {
  local args filter_part focus target first last inner bare marker_at marker_end i before after allowed_targets
  local repeat="" runs="" flag error
  args="$(trim "${1-}")"
  filter_part="$args"
  focus=""
  target=""
  allowed_targets="$(normalize_filter "${4-}")"

  REQUEST_FILTER=""
  REQUEST_FOCUS=""
  REQUEST_TARGET=""
  REQUEST_REPEAT=""
  REQUEST_RUNS=""
  REQUEST_ERROR=""

  if [[ "${2-}" == "true" ]]; then
    marker_at=-1
    marker_end=-1
    for (( i = 0; i <= ${#args} - 7; i++ )); do
      [[ "${args:i:7}" == "--focus" ]] || continue
      before="${args:i-1:1}"
      after="${args:i+7:1}"
      if (( i > 0 )) && [[ "$before" != [[:space:]] ]]; then
        continue
      fi
      if (( i + 7 < ${#args} )) && [[ "$after" != [[:space:]] ]]; then
        continue
      fi
      marker_at=$i
      marker_end=$((i + 7))
      break
    done

    if (( marker_at >= 0 )); then
      filter_part="${args:0:marker_at}"
      focus="${args:marker_end}"

      focus="$(trim "$focus")"
      if (( ${#focus} >= 2 )); then
        first="${focus:0:1}"
        last="${focus: -1}"
        inner="${focus:1:${#focus}-2}"
        bare="${inner//\\$first/}"
        if [[ "$first" == "$last" && ( "$first" == '"' || "$first" == "'" ) && "$bare" != *"$first"* ]]; then
          focus="$inner"
        elif [[ "${3-}" == "true" && "$focus" =~ (^|[[:space:]])--target($|[[:space:]]) ]]; then
          REQUEST_FILTER="$(normalize_filter "$filter_part")"
          REQUEST_ERROR="malformed-target"
          return 0
        fi
      fi

      if [[ -z "$focus" ]]; then
        REQUEST_FILTER="$(normalize_filter "$filter_part")"
        REQUEST_ERROR="malformed-focus"
        return 0
      fi
    fi
  fi
  REQUEST_FOCUS="$focus"

  for flag in repeat runs; do
    if [[ "$flag" == "repeat" && "${5-}" != "true" ]] || [[ "$flag" == "runs" && "${6-}" != "true" ]]; then
      continue
    fi
    take_count_option "--${flag}" "$filter_part"
    filter_part="$OPTION_REST"
    [[ "$OPTION_FOUND" == "true" ]] || continue
    error="$OPTION_ERROR"
    if [[ -z "$error" ]]; then
      if [[ "$flag" == "repeat" ]]; then
        error="$(count_error "$OPTION_VALUE" "$REPEAT_MAX")"
      else
        error="$(count_error "$OPTION_VALUE" "$RUNS_MAX")"
      fi
    fi
    case "$error" in
      "") ;;
      out-of-range)
        REQUEST_FILTER="$(normalize_filter "$filter_part")"
        REQUEST_ERROR="${flag}-out-of-range"
        return 0
        ;;
      *)
        REQUEST_FILTER="$(normalize_filter "$filter_part")"
        REQUEST_ERROR="malformed-${flag}"
        return 0
        ;;
    esac
    if [[ "$flag" == "repeat" ]]; then
      repeat="$((10#$OPTION_VALUE))"
    else
      runs="$((10#$OPTION_VALUE))"
    fi
  done
  # Combining them would cost runs x repeat; refused until someone needs it.
  if [[ -n "$repeat" && -n "$runs" ]]; then
    REQUEST_FILTER="$(normalize_filter "$filter_part")"
    REQUEST_ERROR="repeat-and-runs"
    return 0
  fi
  # One run is what a plain command does, so it keeps the plain identity.
  [[ "$runs" == "1" ]] && runs=""

  if [[ "${3-}" == "true" ]]; then
    marker_at=-1
    marker_end=-1
    for (( i = 0; i <= ${#filter_part} - 8; i++ )); do
      [[ "${filter_part:i:8}" == "--target" ]] || continue
      before="${filter_part:i-1:1}"
      after="${filter_part:i+8:1}"
      if (( i > 0 )) && [[ "$before" != [[:space:]] ]]; then
        continue
      fi
      if (( i + 8 < ${#filter_part} )) && [[ "$after" != [[:space:]] ]]; then
        continue
      fi
      marker_at=$i
      marker_end=$((i + 8))
      break
    done

    if (( marker_at >= 0 )); then
      target="$(trim "${filter_part:marker_end}")"
      filter_part="${filter_part:0:marker_at}"
      REQUEST_FILTER="$(normalize_filter "$filter_part")"
      REQUEST_TARGET="$target"

      if [[ -z "$target" || "$target" == *[[:space:]]* ]]; then
        REQUEST_ERROR="malformed-target"
        return 0
      fi
      if [[ " $allowed_targets " != *" $target "* ]]; then
        REQUEST_ERROR="invalid-target"
        return 0
      fi
    fi
  fi

  REQUEST_FILTER="$(normalize_filter "$filter_part")"
  REQUEST_FOCUS="$focus"
  REQUEST_TARGET="$target"
  REQUEST_REPEAT="$repeat"
  REQUEST_RUNS="$runs"
}

# request_identity <filter> <focus> <target>
# Prefixes prevent label, focus, and target requests from colliding. Focus is
# hashed before normalization because regex whitespace matters. No target keeps
# the old identity.
request_identity() {
  local identity
  if [[ -z "${2-}" ]]; then
    identity="label-request ${1-}"
  else
    identity="focused-request ${1-} focus-digest-$(short_digest "$2")"
  fi

  if [[ -n "${3-}" ]]; then
    printf 'targeted-%s target-%s' "$identity" "$3"
  else
    printf '%s' "$identity"
  fi
}

# request_display <filter> <focus> <target> [option] — human-readable command
# suffix for checks. option, e.g. "--runs 3", goes before the focus like typed.
request_display() {
  local request="${1-}"
  if [[ -n "${3-}" ]]; then
    request="${request} --target ${3}"
  fi
  if [[ -n "${4-}" ]]; then
    request="${request} ${4}"
  fi
  if [[ -n "${2-}" ]]; then
    request="${request} --focus \"${2}\""
  fi
  printf '%s' "$request"
}

# filter_is_balanced <string> — true when no ")" precedes its "(" and none is
# left open. Callers wrap the filter and append guards, `(<filter>) && !x`. An
# unmatched ")" ends that wrapper early, and Ginkgo binds && tighter than ||, so
# `a) || x` puts x outside the guard.
filter_is_balanced() {
  local s="${1-}" depth=0 i
  for (( i = 0; i < ${#s}; i++ )); do
    case "${s:i:1}" in
      "(") depth=$(( depth + 1 )) ;;
      ")") depth=$(( depth - 1 )) ;;
    esac
    if (( depth < 0 )); then
      return 1
    fi
  done
  (( depth == 0 ))
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
  local normalized slug
  normalized="$(normalize_filter "${1-}")"
  slug="$(sanitize_slug "$normalized" "${2:-40}")"
  printf '%s-%s' "${slug:-filter}" "$(short_digest "$normalized")"
}

# check_name <prefix> <request> [max-length]
# The display name of the check-run, derived from user input, so it is
# sanitized and bounded. When the request is too long to show in full the name
# carries a digest of the whole request, because this name is also the dedupe
# key: two different long requests that truncated to the same text would
# otherwise be treated as the same in-flight run.
check_name() {
  local prefix="${1-}" request="${2-}" max="${3:-60}" cleaned
  cleaned="$request"
  cleaned="$(printf '%s' "$cleaned" | LC_ALL=C tr -cd '\040-\176')"

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

# has_write_permission <repository-permission>
has_write_permission() {
  case "${1-}" in
    write|maintain|admin) return 0 ;;
    *) return 1 ;;
  esac
}

# refusal_details <reason> <command> <allowed-targets>
# Convert a machine-readable start refusal into presentation-ready text so
# callers do not have to reproduce a long expression tree in workflow YAML.
# target-not-selected is routing state rather than a refusal and stays silent.
# shellcheck disable=SC2034 # REFUSAL_* are outputs for start.sh and tests.
refusal_details() {
  local reason="${1-}" command_word="${2:-/test-e2e}" allowed_targets="${3-}"
  local target allowed_display="" flag max

  REFUSAL_TITLE=""
  REFUSAL_GUIDANCE=""

  case "$reason" in
    ""|target-not-selected)
      return 0
      ;;
    malformed-focus)
      REFUSAL_TITLE="Focus value is missing"
      REFUSAL_GUIDANCE="Add a value after --focus. For example: \`${command_word} snapshots --focus \"creates snapshots\"\`."
      ;;
    malformed-target)
      REFUSAL_TITLE="Target option is not valid"
      REFUSAL_GUIDANCE="Add one target before \`--focus\`. For example: \`${command_word} snapshots --target pro\`."
      ;;
    malformed-repeat|malformed-runs)
      flag="${reason#malformed-}"
      REFUSAL_TITLE="\`--${flag}\` needs a number"
      REFUSAL_GUIDANCE="Give it one whole number before \`--focus\`. For example: \`${command_word} snapshots --${flag} 3\`."
      ;;
    repeat-out-of-range|runs-out-of-range)
      flag="${reason%-out-of-range}"
      max="$REPEAT_MAX"
      [[ "$flag" == "runs" ]] && max="$RUNS_MAX"
      REFUSAL_TITLE="\`--${flag}\` is out of range"
      REFUSAL_GUIDANCE="Use a number from 1 to ${max}."
      ;;
    repeat-and-runs)
      REFUSAL_TITLE="\`--repeat\` and \`--runs\` together"
      REFUSAL_GUIDANCE="Use one of them per command: \`--repeat\` repeats the suite within one run, \`--runs\` starts independent runs."
      ;;
    invalid-target)
      REFUSAL_TITLE="Invalid target"
      if [[ -z "$allowed_targets" ]]; then
        REFUSAL_GUIDANCE="No targets are configured."
      else
        for target in $allowed_targets; do
          if [[ -n "$allowed_display" ]]; then
            allowed_display+=", "
          fi
          allowed_display+="\`${target}\`"
        done
        REFUSAL_GUIDANCE="Use one of these targets: ${allowed_display}."
      fi
      ;;
    fork)
      REFUSAL_TITLE="\`fork\`"
      REFUSAL_GUIDANCE="This command cannot run on pull requests from forks."
      ;;
    insufficient-permission)
      REFUSAL_TITLE="\`insufficient-permission\`"
      REFUSAL_GUIDANCE="You need repository access to run the command. On a pull request from a fork, you need write access."
      ;;
    rerun-not-allowed)
      REFUSAL_TITLE="\`rerun-not-allowed\`"
      REFUSAL_GUIDANCE="Re-runs are refused on pull requests from forks. Comment \`${command_word}\` again instead."
      ;;
    permission-unreadable)
      REFUSAL_TITLE="\`permission-unreadable\`"
      REFUSAL_GUIDANCE="Your repository permission could not be checked. Please try the command again."
      ;;
    empty-filter)
      REFUSAL_TITLE="\`empty-filter\`"
      REFUSAL_GUIDANCE="Give it a label filter, for example \`${command_word} snapshots\`."
      ;;
    malformed-filter)
      REFUSAL_TITLE="\`malformed-filter\`"
      REFUSAL_GUIDANCE="The filter has unbalanced parentheses."
      ;;
    not-a-pull-request)
      REFUSAL_TITLE="\`not-a-pull-request\`"
      REFUSAL_GUIDANCE="Run this command on a pull request."
      ;;
    pull-request-closed)
      REFUSAL_TITLE="\`pull-request-closed\`"
      REFUSAL_GUIDANCE="Reopen the pull request before running the command."
      ;;
    pull-request-unreadable)
      REFUSAL_TITLE="\`pull-request-unreadable\`"
      REFUSAL_GUIDANCE="The pull request could not be read. Re-run the command; see the run log if it fails again."
      ;;
    check-run-not-created)
      REFUSAL_TITLE="\`check-run-not-created\`"
      REFUSAL_GUIDANCE="The check could not be opened. Re-run the command; see the run log if it fails again."
      ;;
    *)
      REFUSAL_TITLE="\`${reason}\`"
      REFUSAL_GUIDANCE="See the run log for details."
      ;;
  esac
}

# emit <name> <value> — write a step output and echo it for the log.
# dispatch_ref_for <is-fork> <head-ref> <base-ref> — the ref whose workflow a
# caller dispatches: the target branch for forks, the pull request's otherwise.
dispatch_ref_for() {
  if [[ "${1-}" == "true" ]]; then printf '%s' "${3-}"; else printf '%s' "${2-}"; fi
}

# finishes_with_app <workflow-yaml> — true when a finish step of this action in
# the workflow receives both app credentials, the pair the mint step needs. Only
# then can that workflow complete a check-run the app opened. Unparseable YAML or
# no yq is false.
finishes_with_app() {
  command -v yq >/dev/null 2>&1 || return 1
  yq -e '[.. | select(tag == "!!map" and has("uses"))
          | select(.uses | test("comment-triggered-check"))
          | select(.with.mode == "finish")
          | select((.with["app-client-id"] // "") != "" and (.with["app-private-key"] // "") != "")]
          | length > 0' \
    <<< "${1-}" >/dev/null 2>&1
}

emit() {
  printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
  printf '%s=%s\n' "$1" "$2"
}

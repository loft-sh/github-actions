#!/usr/bin/env bash
# Reports on one version string with semstat and writes the answers to
# GITHUB_OUTPUT.
#
# An invalid version is an answer, not a failure: the step stays green and the
# caller decides, which is what the node action this replaces did and what its
# callers gate on. The only hard failures are a missing version input and a
# broken environment.
#
# Required environment:
#   SEMSTAT_BIN       path to the semstat binary.
#   INPUT_VERSION     version string to report on.
#   GITHUB_OUTPUT     standard GitHub Actions step output file.
#
# Optional environment:
#   INPUT_COMPARE_TO  second version to order INPUT_VERSION against.
set -uo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${SEMSTAT_BIN:?SEMSTAT_BIN is required}"

# @actions/core.getInput trimmed by default and the node action this replaces ran
# on the trimmed value, so callers reading parsed_version.raw back out and putting
# it in a tag name never saw padding. semstat parses a padded version happily and
# echoes the padding back in raw, so the trim has to happen here.
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  printf '%s' "${value%"${value##*[![:space:]]}"}"
}

# getInput checked `required` against the untrimmed value and only then trimmed,
# so a whitespace-only version was an invalid version rather than a missing one.
# Both spellings are kept for that distinction.
RAW_VERSION="${INPUT_VERSION-}"
VERSION="$(trim "$RAW_VERSION")"
COMPARE_TO="$(trim "${INPUT_COMPARE_TO-}")"

# A delimiter the input cannot contain, so a version carrying a newline writes
# one output rather than forging several.
delimiter="SEMSTAT_EOF_$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
if [ "$delimiter" = "SEMSTAT_EOF_" ]; then
  delimiter="SEMSTAT_EOF_${RANDOM}${RANDOM}${RANDOM}"
fi

# set -e is deliberately off in this script, so the write is checked here: a
# GITHUB_OUTPUT that could not be written to would otherwise leave the caller
# reading empty outputs off a green step, which is the same unseeable failure as
# a crash reported as is_valid=false.
emit() {
  if ! printf '%s<<%s\n%s\n%s\n' "$1" "$delimiter" "$2" "$delimiter" >>"$GITHUB_OUTPUT"; then
    echo "::error::could not write ${1} to GITHUB_OUTPUT"
    exit 1
  fi
}

# Workflow commands end at a newline, so anything carrying one could close the
# line it sits on and have the rest read as a command of its own, including
# ::stop-commands::, which would silence annotations for the rest of the job.
# Every echo below that interpolates a version or semstat's output goes through
# this, not only the ones that look like commands.
sanitize() {
  printf '%s' "$1" | tr '\r\n' '  '
}

# Runs semstat, leaving its stdout in $semstat_output and its status in
# $semstat_status. `expected` is the comma-separated set of statuses that are
# answers for this call; anything else is the binary failing to run or being
# called wrongly (64), which must fail the step rather than be reported as a
# fact about the version. Reporting a
# crash as `is_valid=false` on a green step is the failure mode this action's
# callers cannot see.
run_semstat() {
  local expected="$1" command="$2"
  shift 2

  semstat_output="$("$SEMSTAT_BIN" "$command" "$@" 2>"$stderr_file")"
  semstat_status=$?

  case ",${expected}," in
    *",${semstat_status},"*) return 0 ;;
  esac

  echo "::error::semstat ${command} exited ${semstat_status}: $(sanitize "$(cat "$stderr_file")")"
  exit 1
}

# Reads one field out of what `semstat parse` printed, leaving it in $field.
# jq's status is checked for the same reason semstat's is: a jq that could not
# read its input would otherwise leave `prerelease` empty and have a release
# candidate reported as stable on a green step. The filters error on an absent
# field rather than let jq print the literal "null", so a schema that moved
# under us fails the step too. The value comes back in a global because an exit
# inside a command substitution would only leave its own subshell.
# shellcheck disable=SC2016  # $key is a jq variable, not a shell one
NUMBER_FIELD='if (.[$key] | type) == "number" then .[$key] | tostring else error("no numeric " + $key) end'
# shellcheck disable=SC2016  # $key is a jq variable, not a shell one
OPTIONAL_FIELD='if has($key) then .[$key] // "" else error("no " + $key) end'

jq_field() {
  local name="$1" filter="$2"
  if ! field="$(jq -r --arg key "$name" "$filter" <<<"$parsed" 2>"$stderr_file")"; then
    echo "::error::could not read ${name} out of what semstat parse printed: $(sanitize "$(cat "$stderr_file")")"
    exit 1
  fi
}

# Every output is written on every path. A caller reading `release_type` must
# never see the value left by nothing at all.
emit_empty_details() {
  emit is_stable ""
  emit release_type ""
  emit major ""
  emit minor ""
  emit patch ""
  emit prerelease ""
  emit build ""
}

emit_empty_comparison() {
  emit comparison ""
  emit is_greater ""
}

# Checked, because every semstat call below redirects to this path: an empty
# stderr_file makes the redirect itself fail with status 1, which for
# `validate` is inside the set of statuses that mean "not a version" and would
# report a perfectly good compare_to as one.
if ! stderr_file="$(mktemp)" || [ -z "$stderr_file" ]; then
  echo "::error::could not create a temporary file to capture semstat's stderr"
  exit 1
fi
trap 'rm -f "$stderr_file"' EXIT

# semstat reads any argument starting with a dash as an option and exits 64 for
# it, which this script treats as misuse and fails the step on. No semver starts
# with a dash, so the answer is known without asking, and asking would turn an
# invalid version into a broken step.
starts_with_dash() {
  case "$1" in
    -*) return 0 ;;
    *) return 1 ;;
  esac
}

# Both callers of this print their own reason: on the dash path there is no
# semstat stderr to quote, and on the parse path there is.
report_invalid_version() {
  emit is_valid "false"
  emit parsed_version ""
  # Verbatim from the node action: callers assert on this string.
  emit error_message "Invalid semver format: '${VERSION}'"
  emit_empty_details
  emit_empty_comparison
  echo "::warning::$(sanitize "$1")"
  echo "Version '$(sanitize "$VERSION")' is not a valid semver"
  exit 0
}

if [ -z "$RAW_VERSION" ]; then
  emit is_valid "false"
  emit parsed_version ""
  emit error_message "Input required and not supplied: version"
  emit_empty_details
  emit_empty_comparison
  echo "::error::Action failed with error: Input required and not supplied: version"
  exit 1
fi

# Below the missing-input check rather than above it, so the two broken things a
# caller can hand this action stay distinguishable: a runner without jq is not a
# reason to stop reporting that `version:` was never supplied.
if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required to read semstat's output and is not on PATH"
  exit 1
fi

echo "Validating version: $(sanitize "$VERSION")"

if starts_with_dash "$VERSION"; then
  report_invalid_version "a version cannot start with '-'"
fi

# 2 is "I could not read that", which for parse is the same as "not a version".
# Misuse is 64 and so falls outside this set, which is what keeps a semstat whose
# parse surface moved from being reported as a version that is not one.
run_semstat 0,2 parse "$VERSION"
parsed="$semstat_output"

if [ "$semstat_status" -ne 0 ]; then
  report_invalid_version "$(cat "$stderr_file")"
fi

# Everything below is read and checked before anything is emitted. A caller with
# continue-on-error would otherwise be unable to tell a semstat whose surface
# moved from a version there was legitimately nothing to say about: both would
# leave it the same set of written outputs.
jq_field major "$NUMBER_FIELD"
major="$field"
jq_field minor "$NUMBER_FIELD"
minor="$field"
jq_field patch "$NUMBER_FIELD"
patch="$field"
jq_field prerelease "$OPTIONAL_FIELD"
prerelease="$field"
jq_field build "$OPTIONAL_FIELD"
build="$field"

# semstat routes the suffixes the vCluster release pipeline knows and refuses the
# rest. Refusing is not a reason to fail here: the node action accepted every
# valid semver, so a caller passing one that happens to be unroutable has to keep
# working. It gets an empty release_type.
run_semstat 0,2 type "$VERSION"
if [ "$semstat_status" -eq 0 ]; then
  # An exit 0 says semstat answered, not that it answered with a channel this
  # action documents. Callers gate on these strings, so one that moved has to
  # fail the step rather than be passed through for `release_type == 'stable'`
  # to quietly not match.
  case "$semstat_output" in
    stable | alpha | beta | rc | next | next-internal) ;;
    *)
      echo "::error::semstat type answered $(sanitize "$semstat_output"), which is not a release channel this action knows"
      exit 1
      ;;
  esac
  release_type="$semstat_output"
else
  release_type=""
  # A plain log line rather than a ::warning::. The version is valid and a suffix
  # this pipeline does not route is an ordinary answer about it, so a caller that
  # reads nothing but is_valid would otherwise collect an annotation on its run
  # for a tag that is fine.
  echo "No release channel for '$(sanitize "$VERSION")'; release_type is left empty: $(sanitize "$(cat "$stderr_file")")"
fi

# Read off the channel semstat answered with, so what counts as stable is
# semstat's call and not a second rule kept here. The parsed suffix is only the
# fallback for a version semstat refused to route, which leaves no channel to
# read it off; the two agree today, and this is what keeps them agreeing if
# semstat's notion of stable ever moves.
if [ -n "$release_type" ]; then
  if [ "$release_type" = "stable" ]; then
    is_stable="true"
  else
    is_stable="false"
  fi
elif [ -z "$prerelease" ]; then
  is_stable="true"
else
  is_stable="false"
fi

echo "Version '$(sanitize "$VERSION")' is a valid semver"
echo "Parsed: $(sanitize "$parsed")"

comparison=""
is_greater=""

# The skipped cases are said out loud, because empty comparison outputs otherwise
# cannot be told from a `compare_to:` expression that resolved to nothing.
if [ -z "$COMPARE_TO" ]; then
  echo "No compare_to given; comparison and is_greater are left empty"
elif starts_with_dash "$COMPARE_TO"; then
  echo "::warning::compare_to: a version cannot start with '-'"
else
  # validate answers 1 for "not a version"; it is the only command here with an
  # answer that means no.
  run_semstat 0,1 validate "$COMPARE_TO"
  if [ "$semstat_status" -ne 0 ]; then
    echo "::warning::$(sanitize "compare_to: $(cat "$stderr_file")")"
  else
    # Both versions are known readable by now, so compare has an answer. A 2 here
    # would mean semstat disagrees with itself, not that the versions are
    # unordered.
    run_semstat 0 compare "$VERSION" "$COMPARE_TO"
    comparison="$semstat_output"

    # is_greater is false for everything that is not a 1, so an answer outside
    # the ordering would come back as a confident "does not outrank" instead of
    # as the broken binary it is.
    case "$comparison" in
      -1 | 0 | 1) ;;
      *)
        echo "::error::semstat compare answered $(sanitize "$comparison"), not -1, 0 or 1"
        exit 1
        ;;
    esac

    if [ "$comparison" = "1" ]; then
      is_greater="true"
    else
      is_greater="false"
    fi
  fi
fi

emit is_valid "true"
emit parsed_version "$parsed"
emit error_message ""

emit major "$major"
emit minor "$minor"
emit patch "$patch"
emit prerelease "$prerelease"
emit build "$build"
emit is_stable "$is_stable"
emit release_type "$release_type"

emit comparison "$comparison"
emit is_greater "$is_greater"

if [ -n "$comparison" ]; then
  echo "Comparison of '$(sanitize "$VERSION")' against '$(sanitize "$COMPARE_TO")': ${comparison}"
fi

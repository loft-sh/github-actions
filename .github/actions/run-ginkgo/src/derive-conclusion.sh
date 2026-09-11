#!/usr/bin/env bash
# Derive a check-run conclusion from a Ginkgo JSON report.
#
# Exists because job status cannot express two of the outcomes we publish. It has
# no value for "the filter matched nothing", and Ginkgo exits 0 on an empty
# selection, so a job that succeeded is not evidence that anything was tested.
#
# The consumer treats a value from here as authoritative over the job result, so
# every rule below has to fail towards failure rather than away from it. An
# earlier version counted `It` nodes and looked for three spec states; a failed
# BeforeSuite produces no `It` nodes at all, so it reported `neutral` for a suite
# that never started.
#
# Inputs (env):
#   INPUT_REPORT                       path to the Ginkgo JSON report
#   INPUT_EMPTY_SELECTION_CONCLUSION   what an empty selection reports; neutral
#                                      or failure, defaulting to neutral
#   INPUT_FOCUS                        optional focus expression; an empty
#                                      focused selection always fails
#
# Writes to $GITHUB_OUTPUT:
#   check-conclusion=success|failure|neutral|timed_out, or nothing at all when
#   there is no report to read. Emitting nothing is a valid answer: the caller
#   falls back to job results, which fail closed.
set -euo pipefail

report="${INPUT_REPORT:-test-reports/report.json}"

emit() {
  echo "check-conclusion=$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "check-conclusion=$1" >> "$GITHUB_OUTPUT"
  fi
}

# No link: the consumer appends one.
EMPTY_SELECTION_SUMMARY="Nothing ran: the label filter matched no specs.

An unknown label is not an error in Ginkgo, it just matches nothing. Check the
filter for a typo and remember that command runs apply built-in exclusions for
non-default and hyperscaler tests."

FOCUSED_EMPTY_SELECTION_SUMMARY="Nothing ran: no specs remained after applying the focus expression.

Ginkgo reports only the combined label and focus selection, so check both for a
typo."

# Multi-line needs the heredoc form; name=value truncates at the first newline.
emit_summary() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  {
    echo "check-summary<<CHECK_SUMMARY_EOF"
    printf '%s\n' "$1"
    echo "CHECK_SUMMARY_EOF"
  } >> "$GITHUB_OUTPUT"
}

# derive_conclusion <report-json> — the whole decision, as a pure function over
# the report text so bats can exercise it without a file or a runner.
#
# Order matters as much as the rules do, because `neutral` is an ACCEPTABLE
# verdict downstream. Anything ambiguous or failed has to be classified before
# the zero-selection branch can claim it, or a suite that died before selecting
# anything reports as "nothing to run".
derive_conclusion() {
  local json="$1" will_run timed_out succeeded_all

  # 1. The report has to be the shape we think it is. Syntactically valid JSON is
  #    not enough, and the failure is silent rather than loud: `jq length` on the
  #    string "foo" is 3 and on the number 42 is 42, so neither is caught by an
  #    emptiness check, while `[] | all` on a non-array is true, so neither is
  #    caught by the suite check either. Both would sail through to the
  #    zero-selection branch and report `neutral`, which is an ACCEPTABLE verdict
  #    downstream. Anything not shaped like a Ginkgo report is a failure.
  #
  #    `and` short-circuits in jq, so the array checks never evaluate `.[]` on a
  #    scalar.
  if ! printf '%s' "$json" | jq -e '
        type == "array"
        and length > 0
        and all(.[];
          type == "object"
          and (.SuiteSucceeded | type) == "boolean"
          and (.PreRunStats.SpecsThatWillRun | type) == "number"
          and (.PreRunStats.SpecsThatWillRun | . >= 0 and . == floor)
          and has("SpecReports")
          and (.SpecReports == null or ((.SpecReports | type) == "array" and all(.SpecReports[]?; type == "object"))))
      ' >/dev/null 2>&1; then
    printf 'failure'
    return 0
  fi

  # 2. Ginkgo's own timeout marks the specs it cut short. Before the general
  #    failure rule, because a timeout is also a non-succeeding suite and would
  #    otherwise be flattened into `failure`.
  timed_out="$(printf '%s' "$json" | jq '[.[]?.SpecReports[]? | select(.State == "timedout")] | length')"
  if [[ "$timed_out" -gt 0 ]]; then
    printf 'timed_out'
    return 0
  fi

  # 3. Any suite that did not succeed. SuiteSucceeded rather than a list of spec
  #    states: Ginkgo has five failure states (failed, panicked, aborted,
  #    interrupted, timedout) and enumerating them breaks quietly when a sixth
  #    appears, while the suite verdict already covers all of them plus setup and
  #    cleanup nodes. Before zero-selection, so a suite that failed having
  #    selected nothing is a failure and not a neutral.
  succeeded_all="$(printf '%s' "$json" | jq '[.[]?.SuiteSucceeded] | all')"
  if [[ "$succeeded_all" != "true" ]]; then
    printf 'failure'
    return 0
  fi

  # 4. Only now can zero mean what it says. PreRunStats.SpecsThatWillRun is the
  #    count remaining after label filtering, so zero across every succeeding
  #    suite is precisely "the filter matched nothing".
  will_run="$(printf '%s' "$json" | jq '[.[]?.PreRunStats.SpecsThatWillRun // 0] | add // 0')"
  if [[ "$will_run" -eq 0 ]]; then
    printf 'neutral'
    return 0
  fi

  printf 'success'
}

main() {
  # An unrecognised value becomes failure, not the neutral default. The only
  # reason to set this input is to be stricter than neutral, so a typo must not
  # silently restore the behaviour the caller was opting out of.
  local empty_conclusion="${INPUT_EMPTY_SELECTION_CONCLUSION:-neutral}"
  case "$empty_conclusion" in
    neutral | failure) ;;
    *)
      echo "::warning::empty-selection-conclusion must be neutral or failure, got '${empty_conclusion}'; using failure"
      empty_conclusion="failure"
      ;;
  esac

  if [[ ! -s "$report" ]]; then
    echo "no ginkgo report at ${report}; leaving the conclusion to the caller"
    return 0
  fi

  local json conclusion
  json="$(cat "$report")"

  if ! printf '%s' "$json" | jq empty 2>/dev/null; then
    # Unparseable is not "nothing ran". Say so and let the caller fail closed.
    echo "::warning::ginkgo report at ${report} is not valid JSON; leaving the conclusion to the caller"
    return 0
  fi

  conclusion="$(derive_conclusion "$json")"
  if [[ "$conclusion" == "neutral" ]]; then
    local summary="$EMPTY_SELECTION_SUMMARY"
    if [[ -n "${INPUT_FOCUS:-}" ]]; then
      summary="$FOCUSED_EMPTY_SELECTION_SUMMARY"
      # generate-summary.sh already fails this case. Keep the published check in
      # agreement with that established run-ginkgo contract.
      conclusion="failure"
    else
      conclusion="$empty_conclusion"
    fi
    echo "::warning::the test selection matched no specs; reporting ${conclusion} rather than success"
    emit_summary "$summary"
  fi
  emit "$conclusion"
}

# Only auto-run when executed directly; sourcing (e.g. from bats) must not.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

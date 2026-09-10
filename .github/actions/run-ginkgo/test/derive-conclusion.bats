#!/usr/bin/env bats
# Tests for derive-conclusion.sh.
#
# The rule under test is that a value from here outranks the job result in the
# consumer, so anything ambiguous must land on `failure`. The cases that matter
# most are the ones where the suite produced no `It` nodes at all.

SCRIPT="$BATS_TEST_DIRNAME/../src/derive-conclusion.sh"

setup() {
  source "$SCRIPT"
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

# report <specs-that-will-run> <suite-succeeded> [spec-json...]
report() {
  local will_run="$1" succeeded="$2"
  shift 2
  local specs=""
  if [[ $# -gt 0 ]]; then specs="$(IFS=,; echo "$*")"; fi
  printf '[{"SuiteSucceeded":%s,"PreRunStats":{"TotalSpecs":9,"SpecsThatWillRun":%s},"SpecReports":[%s]}]' \
    "$succeeded" "$will_run" "$specs"
}

spec() { printf '{"LeafNodeType":"%s","State":"%s"}' "$1" "$2"; }

@test "all specs passed is success" {
  run derive_conclusion "$(report 2 true "$(spec It passed)" "$(spec It passed)")"
  [ "$output" = "success" ]
}

@test "a failed spec is failure" {
  run derive_conclusion "$(report 2 false "$(spec It passed)" "$(spec It failed)")"
  [ "$output" = "failure" ]
}

@test "nothing selected is neutral" {
  run derive_conclusion "$(report 0 true)"
  [ "$output" = "neutral" ]
}

# The case the first version got wrong: a setup failure produces no It nodes, so
# counting them saw an empty suite and called it neutral.
@test "a failed BeforeSuite is failure, not neutral" {
  run derive_conclusion "$(report 5 false "$(spec BeforeSuite failed)")"
  [ "$output" = "failure" ]
}

@test "a failed SynchronizedBeforeSuite is failure" {
  run derive_conclusion "$(report 5 false "$(spec SynchronizedBeforeSuite failed)")"
  [ "$output" = "failure" ]
}

@test "a failed AfterSuite is failure even when every spec passed" {
  run derive_conclusion "$(report 2 false "$(spec It passed)" "$(spec AfterSuite failed)")"
  [ "$output" = "failure" ]
}

# States the enumerating version missed entirely.
@test "an aborted spec is failure" {
  run derive_conclusion "$(report 2 false "$(spec It aborted)")"
  [ "$output" = "failure" ]
}

@test "an interrupted spec is failure" {
  run derive_conclusion "$(report 2 false "$(spec It interrupted)")"
  [ "$output" = "failure" ]
}

@test "a panicked spec is failure" {
  run derive_conclusion "$(report 2 false "$(spec It panicked)")"
  [ "$output" = "failure" ]
}

@test "a hypothetical future failure state is still failure" {
  run derive_conclusion "$(report 2 false "$(spec It somethingnew)")"
  [ "$output" = "failure" ]
}

# timed_out has to survive as its own value, or the conclusion the action
# promises is unreachable.
@test "a timed-out spec is timed_out, not failure" {
  run derive_conclusion "$(report 2 false "$(spec It timedout)")"
  [ "$output" = "timed_out" ]
}

@test "a timeout alongside other failures still reports timed_out" {
  run derive_conclusion "$(report 3 false "$(spec It failed)" "$(spec It timedout)")"
  [ "$output" = "timed_out" ]
}

@test "multiple suites: one failing makes the whole run a failure" {
  json='[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":2},"SpecReports":[]},{"SuiteSucceeded":false,"PreRunStats":{"SpecsThatWillRun":1},"SpecReports":[]}]'
  run derive_conclusion "$json"
  [ "$output" = "failure" ]
}

@test "multiple suites: zero selected across all of them is neutral" {
  json='[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":0},"SpecReports":[]},{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":0},"SpecReports":[]}]'
  run derive_conclusion "$json"
  [ "$output" = "neutral" ]
}

# An earlier version of this test only asserted "not success", which passed while
# the code returned neutral. neutral is an acceptable verdict downstream, so that
# was the bug rather than the assertion being merely loose.
@test "an empty report array is a failure, not neutral" {
  run derive_conclusion '[]'
  [ "$output" = "failure" ]
}

# --- schema validation -------------------------------------------------------
#
# Each of these is syntactically valid JSON, so a parse check does not catch it.
# `jq length` on a scalar returns a number rather than erroring, and `all` over a
# non-array is vacuously true, so without an explicit shape check they all reach
# the zero-selection branch and report neutral.

@test "a JSON string is a failure" {
  run derive_conclusion '"foo"'
  [ "$output" = "failure" ]
}

@test "a JSON number is a failure" {
  run derive_conclusion '42'
  [ "$output" = "failure" ]
}

@test "JSON null is a failure" {
  run derive_conclusion 'null'
  [ "$output" = "failure" ]
}

@test "a bare object rather than an array of suites is a failure" {
  run derive_conclusion '{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":2}}'
  [ "$output" = "failure" ]
}

@test "a stringly-typed SuiteSucceeded is a failure, not a truthy pass" {
  run derive_conclusion '[{"SuiteSucceeded":"true","PreRunStats":{"SpecsThatWillRun":2},"SpecReports":[]}]'
  [ "$output" = "failure" ]
}

@test "a missing PreRunStats is a failure" {
  run derive_conclusion '[{"SuiteSucceeded":true,"SpecReports":[]}]'
  [ "$output" = "failure" ]
}

@test "a stringly-typed SpecsThatWillRun is a failure" {
  run derive_conclusion '[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":"0"},"SpecReports":[]}]'
  [ "$output" = "failure" ]
}

@test "one malformed suite among good ones is a failure" {
  json='[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":2},"SpecReports":[]},{"SuiteSucceeded":null,"PreRunStats":{"SpecsThatWillRun":1},"SpecReports":[]}]'
  run derive_conclusion "$json"
  [ "$output" = "failure" ]
}

@test "a negative SpecsThatWillRun is a failure" {
  run derive_conclusion '[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":-1},"SpecReports":[]}]'
  [ "$output" = "failure" ]
}

@test "a fractional SpecsThatWillRun is a failure" {
  run derive_conclusion '[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":0.5},"SpecReports":[]}]'
  [ "$output" = "failure" ]
}

@test "missing SpecReports is a failure" {
  run derive_conclusion '[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":1}}]'
  [ "$output" = "failure" ]
}

@test "null SpecReports is accepted for a successful empty suite" {
  run derive_conclusion '[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":0},"SpecReports":null}]'
  [ "$output" = "neutral" ]
}

@test "a scalar SpecReports is a failure" {
  run derive_conclusion '[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":1},"SpecReports":"passed"}]'
  [ "$output" = "failure" ]
}

# Ordering: a suite that failed before selecting anything must not be absorbed by
# the zero-selection branch.
@test "a failed suite with zero selected specs is failure, not neutral" {
  run derive_conclusion "$(report 0 false "$(spec BeforeSuite failed)")"
  [ "$output" = "failure" ]
}

@test "a timeout with zero selected specs is timed_out, not neutral" {
  run derive_conclusion "$(report 0 false "$(spec It timedout)")"
  [ "$output" = "timed_out" ]
}

@test "mixed suites where the failing one selected nothing is still failure" {
  json='[{"SuiteSucceeded":true,"PreRunStats":{"SpecsThatWillRun":3},"SpecReports":[]},{"SuiteSucceeded":false,"PreRunStats":{"SpecsThatWillRun":0},"SpecReports":[]}]'
  run derive_conclusion "$json"
  [ "$output" = "failure" ]
}

# --- the script's own I/O ----------------------------------------------------

@test "a missing report emits no conclusion at all" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/absent.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "an unparseable report emits no conclusion and warns" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/bad.json"
  printf 'not json at all' > "$INPUT_REPORT"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "a good report writes the output" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  report 2 true "$(spec It passed)" > "$INPUT_REPORT"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "check-conclusion=success" "$GITHUB_OUTPUT"
}

@test "the zero-selection path warns rather than passing silently" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  report 0 true > "$INPUT_REPORT"
  run bash "$SCRIPT"
  [[ "$output" == *"matched no specs"* ]]
  grep -q "check-conclusion=neutral" "$GITHUB_OUTPUT"
}

# --- empty-selection-conclusion ----------------------------------------------
#
# A hand-typed filter that matches nothing has to fail: GitHub renders neutral as
# a grey non-blocking check, so "nothing ran" reads as fine (DEVOPS-1333).

@test "an empty selection reports failure when the caller asks for it" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  export INPUT_EMPTY_SELECTION_CONCLUSION=failure
  report 0 true > "$INPUT_REPORT"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "check-conclusion=failure" "$GITHUB_OUTPUT"
}

@test "the input only affects the empty selection, never a real result" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  export INPUT_EMPTY_SELECTION_CONCLUSION=failure
  report 2 true "$(spec It passed)" > "$INPUT_REPORT"
  run bash "$SCRIPT"
  grep -q "check-conclusion=success" "$GITHUB_OUTPUT"
}

@test "an unset input keeps the neutral default" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  report 0 true > "$INPUT_REPORT"
  run bash "$SCRIPT"
  grep -q "check-conclusion=neutral" "$GITHUB_OUTPUT"
}

@test "an unrecognised input falls to failure rather than back to neutral" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  export INPUT_EMPTY_SELECTION_CONCLUSION="Failure"
  report 0 true > "$INPUT_REPORT"
  run bash "$SCRIPT"
  [[ "$output" == *"must be neutral or failure"* ]]
  grep -q "check-conclusion=failure" "$GITHUB_OUTPUT"
}

@test "an empty input string keeps the neutral default" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  export INPUT_EMPTY_SELECTION_CONCLUSION=""
  report 0 true > "$INPUT_REPORT"
  run bash "$SCRIPT"
  grep -q "check-conclusion=neutral" "$GITHUB_OUTPUT"
}

# --- check-summary -----------------------------------------------------------
#
# A conclusion alone cannot say why. Mapping an empty selection onto failure
# merges it with a real test failure, and the check then reads as broken code.

@test "an empty selection explains itself" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  report 0 true > "$INPUT_REPORT"
  run bash "$SCRIPT"
  grep -q "check-summary<<" "$GITHUB_OUTPUT"
  grep -q "matched no specs" "$GITHUB_OUTPUT"
}

@test "a focused empty selection explains that the focus matched nothing" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  export INPUT_FOCUS="creates a snapshot"
  report 0 true > "$INPUT_REPORT"
  run bash "$SCRIPT"
  grep -q "no specs remained after applying the focus expression" "$GITHUB_OUTPUT"
  ! grep -q "label filter matched no specs" "$GITHUB_OUTPUT"
}

@test "the summary carries no link, because the consumer appends one" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  report 0 true > "$INPUT_REPORT"
  run bash "$SCRIPT"
  ! grep -q "View the run" "$GITHUB_OUTPUT"
}

@test "a real result emits no summary, leaving the caller's default" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  report 2 true "$(spec It passed)" > "$INPUT_REPORT"
  run bash "$SCRIPT"
  ! grep -q "check-summary" "$GITHUB_OUTPUT"
}

@test "a failure emits no summary either" {
  export INPUT_REPORT="$BATS_TEST_TMPDIR/report.json"
  report 2 false "$(spec It failed)" > "$INPUT_REPORT"
  run bash "$SCRIPT"
  grep -q "check-conclusion=failure" "$GITHUB_OUTPUT"
  ! grep -q "check-summary" "$GITHUB_OUTPUT"
}



#!/usr/bin/env bats
# Tests for action.sh.
#
# commitlint itself is mocked: what matters here is which checks run, which are
# skipped, and how exit codes and outputs are reported. The rules themselves are
# the calling repository's business and are tested there.

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../src/action.sh"

load commitlint_mock

setup() {
  setup_mocks

  WORKDIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  # Range linting checks that its revisions exist, so the fixture is a real
  # repository rather than a bare directory.
  git init -q .
  git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m "chore: base"
  BASE_SHA=$(git rev-parse HEAD)
  git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m "chore: head"
  HEAD_SHA=$(git rev-parse HEAD)
  export BASE_SHA HEAD_SHA

  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output.txt"
  GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  export GITHUB_OUTPUT GITHUB_STEP_SUMMARY

  export INPUT_WORKING_DIRECTORY="$WORKDIR"
  export INPUT_PR_TITLE=""
  export INPUT_FROM=""
  export INPUT_TO="HEAD"
  export INPUT_SKIP_BRANCHES=""
  export INPUT_BRANCH=""
  export INPUT_HEAD_REPOSITORY=""
  export GITHUB_REPOSITORY=""
  export INPUT_CONFIG_PATH=""
  export INPUT_COMMITLINT_VERSION="19.8.1"
  export INPUT_FAIL_ON_WARNINGS="false"
}

output_value() {
  grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

# No line of output may be parseable by the runner as a workflow command other
# than the ones this action emits itself. The runner ends a line on CR as well
# as LF and trims leading whitespace before matching "::", so both have to be
# covered - anchoring on '^::' alone would miss an indented payload.
FORGEABLE='stop-commands|add-mask|set-env|set-output|save-state|echo'

assert_no_forged_commands() {
  local normalised
  # Treat CR as a line break, exactly as the runner does.
  normalised=$(printf '%s\n' "$output" | tr '\r' '\n')

  if printf '%s\n' "$normalised" | grep -E "^[[:space:]]*::(${FORGEABLE})" ; then
    echo "forged workflow command found above" >&2
    return 1
  fi
}

# The companion invariant, and the one assert_no_forged_commands cannot see: an
# untrusted value sitting on a legitimate ::warning:: or ::group:: is percent-
# decoded into that annotation, so it arrives carrying whatever line breaks it
# encoded while the raw log still looks like one tidy line. Assert the value
# never reaches such a line at all, which is the rule action.sh states.
assert_not_on_command_line() {
  local normalised
  # Same CR normalisation as above: a value carried onto an annotation line by a
  # preceding CR is on a command line as far as the runner is concerned, even
  # though the raw output shows one harmless-looking line.
  normalised=$(printf '%s\n' "$output" | tr '\r' '\n')

  if printf '%s\n' "$normalised" | grep -E '^[[:space:]]*::' | grep -qF -- "$1"; then
    echo "untrusted value '$1' reached a workflow-command line" >&2
    return 1
  fi
}

# A bare `! cmd` is exempt from errexit, so bats reports it only when it is the
# test's last statement; anywhere else it is inert and the assertion holds
# nothing. Every negative assertion goes through one of these instead, which
# fail the test wherever they appear - including after a line is added below
# them, which is how the inert ones got there.
assert_summary_lacks() {
  if grep -qF -- "$1" "$GITHUB_STEP_SUMMARY"; then
    echo "job summary contains '$1'" >&2
    return 1
  fi
}

assert_no_call_matching() {
  if calls | grep -q -e "$1"; then
    echo "unexpected invocation matching '$1'" >&2
    return 1
  fi
}

# "commitlint never ran at all" is the wrong invariant to assert anywhere after
# resolve_commitlint, because verify_commitlint_runs probes the binary with
# --version first and that probe is logged like any other call. What callers
# care about is that nothing was handed a message to judge.
assert_nothing_was_linted() {
  if calls | grep -Ev -- '--version' | grep -qE '^(commitlint|npx)'; then
    echo "commitlint was invoked to lint something" >&2
    return 1
  fi
}

@test "lints the pr title and passes" {
  export INPUT_PR_TITLE="fix(cli): stop leaking the kubeconfig"

  run -0 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "pass" ]
  [ "$(output_value commits-result)" = "skipped" ]
  [ "$(output_value skipped)" = "false" ]
}

@test "fails when the pr title is rejected" {
  export INPUT_PR_TITLE="bugfix: nope"
  export COMMITLINT_MOCK_TITLE_EXIT=1

  run -1 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "fail" ]
  grep -q "Commitlint failed" "$GITHUB_STEP_SUMMARY"
}

@test "lints a commit range" {
  export INPUT_FROM="$BASE_SHA"
  export INPUT_TO="$HEAD_SHA"

  run -0 "$SCRIPT"

  [ "$(output_value commits-result)" = "pass" ]
  [ "$(output_value pr-title-result)" = "skipped" ]
  calls | grep -q -- "--from $BASE_SHA --to $HEAD_SHA"
}

@test "fails when a commit in the range is rejected" {
  export INPUT_FROM="$BASE_SHA"
  export COMMITLINT_MOCK_RANGE_EXIT=1

  run -1 "$SCRIPT"

  [ "$(output_value commits-result)" = "fail" ]
}

@test "runs both checks even when the title check fails" {
  export INPUT_PR_TITLE="bugfix: nope"
  export INPUT_FROM="$BASE_SHA"
  export COMMITLINT_MOCK_TITLE_EXIT=1

  run -1 "$SCRIPT"

  # The range check must still have run, so one push surfaces both problems.
  [ "$(output_value commits-result)" = "pass" ]
  [ "$(output_value pr-title-result)" = "fail" ]
  calls | grep -q -- "--from $BASE_SHA"
}

@test "skips everything when the branch matches skip-branches" {
  export INPUT_BRANCH="sync-from-oss/main"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_PR_TITLE="whatever, this is never linted"
  export COMMITLINT_MOCK_EXIT=1

  run -0 "$SCRIPT"

  [ "$(output_value skipped)" = "true" ]
  [ "$(output_value pr-title-result)" = "skipped" ]
  [ ! -s "$CALL_LOG" ]
}

@test "matches any pattern in a comma-separated skip list" {
  export INPUT_BRANCH="backport/v0.36"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*, backport/*"
  export INPUT_PR_TITLE="anything"

  run -0 "$SCRIPT"

  [ "$(output_value skipped)" = "true" ]
}

@test "does not skip a branch that only resembles the pattern" {
  export INPUT_BRANCH="feat/sync-from-oss-docs"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_PR_TITLE="feat(docs): describe the sync"

  run -0 "$SCRIPT"

  [ "$(output_value skipped)" = "false" ]
  calls | grep -q "commitlint"
}

@test "fails when given nothing to lint" {
  run -1 "$SCRIPT"

  [[ "$output" == *"Nothing to lint"* ]]
  # Every declared output must be written on every exit path, or a caller
  # branching on them reads an empty string.
  [ "$(output_value pr-title-result)" = "skipped" ]
  [ "$(output_value commits-result)" = "skipped" ]
}

@test "ignores skip-branches when the branch belongs to a fork" {
  # A fork's branch name is chosen by the PR author, so honouring the skip list
  # there would let anyone opt out of linting.
  export INPUT_BRANCH="sync-from-oss/main"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_HEAD_REPOSITORY="a-contributor/vcluster-pro"
  export GITHUB_REPOSITORY="loft-sh/vcluster-pro"
  export INPUT_PR_TITLE="bugfix: sneaking this past the linter"
  export COMMITLINT_MOCK_TITLE_EXIT=1

  run -1 "$SCRIPT"

  [ "$(output_value skipped)" = "false" ]
  [ "$(output_value pr-title-result)" = "fail" ]
  [[ "$output" == *"Ignoring skip-branches"* ]]
}

@test "still skips when the branch belongs to the repository itself" {
  export INPUT_BRANCH="sync-from-oss/main"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_HEAD_REPOSITORY="loft-sh/vcluster-pro"
  export GITHUB_REPOSITORY="loft-sh/vcluster-pro"
  export INPUT_PR_TITLE="anything"

  run -0 "$SCRIPT"

  [ "$(output_value skipped)" = "true" ]
}

@test "reports a commitlint that cannot start as a CI problem" {
  export INPUT_PR_TITLE="fix: something"
  export COMMITLINT_MOCK_VERSION_EXIT=127

  run -1 "$SCRIPT"

  # Not "your commit message is wrong" - the message was never linted.
  [[ "$output" == *"not a problem with the commit messages"* ]]
  # "error", not "skipped": a caller must be able to tell "could not run" from
  # "no title check was requested".
  [ "$(output_value pr-title-result)" = "error" ]
  grep -q "could not run" "$GITHUB_STEP_SUMMARY"
}

@test "distinguishes a commitlint crash from a rejected message" {
  export INPUT_PR_TITLE="fix: something"
  export COMMITLINT_MOCK_TITLE_EXIT=127

  run -1 "$SCRIPT"

  grep -q "not a problem with the commit messages" "$GITHUB_STEP_SUMMARY"
  # The output must not say "fail", or a caller acting on it contradicts the log.
  [ "$(output_value pr-title-result)" = "error" ]
}

# --strict changes commitlint's exit contract to 2 for warnings and 3 for
# errors, never 1. Treating those as crashes would report every real problem
# as a CI outage, which is the opposite of what fail-on-warnings is for.
@test "treats strict-mode warning exit 2 as a message problem" {
  export INPUT_FAIL_ON_WARNINGS="true"
  export INPUT_PR_TITLE="fix(unknown-scope): something"
  export COMMITLINT_MOCK_TITLE_EXIT=2

  run -1 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "fail" ]
  [[ "$output" != *"not a problem with the commit messages"* ]]
  grep -q "Commitlint failed" "$GITHUB_STEP_SUMMARY"
}

@test "treats strict-mode error exit 3 as a message problem" {
  export INPUT_FAIL_ON_WARNINGS="true"
  export INPUT_PR_TITLE="bugfix: nope"
  export COMMITLINT_MOCK_TITLE_EXIT=3

  run -1 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "fail" ]
  grep -q "Commitlint failed" "$GITHUB_STEP_SUMMARY"
}

@test "still treats a crash as a crash in strict mode" {
  export INPUT_FAIL_ON_WARNINGS="true"
  export INPUT_PR_TITLE="fix: something"
  export COMMITLINT_MOCK_TITLE_EXIT=127

  run -1 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "error" ]
  grep -q "not a problem with the commit messages" "$GITHUB_STEP_SUMMARY"
}

@test "exit 2 is a crash when not in strict mode" {
  # Without --strict commitlint never returns 2, so it means something else.
  export INPUT_PR_TITLE="fix: something"
  export COMMITLINT_MOCK_TITLE_EXIT=2

  run -1 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "error" ]
}

@test "treats strict-mode exit 1 as a crash, not a message problem" {
  # --strict never returns 1 for a message problem, so 1 there is unambiguously
  # a setup failure: an unresolvable extends, or a --from missing from a shallow
  # clone. Both were measured at exit 1 against commitlint 19.8.1.
  export INPUT_FAIL_ON_WARNINGS="true"
  export INPUT_PR_TITLE="fix: a perfectly fine subject"
  export COMMITLINT_MOCK_TITLE_EXIT=1

  run -1 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "error" ]
  grep -q "not a problem with the commit messages" "$GITHUB_STEP_SUMMARY"
}

@test "reports both a real problem and a crash in the same run" {
  # Otherwise the contributor reads "this is a CI problem" while a genuine
  # message problem sits unreported in the outputs.
  export INPUT_PR_TITLE="bugfix: a real problem"
  export INPUT_FROM="$BASE_SHA"
  export COMMITLINT_MOCK_TITLE_EXIT=1
  export COMMITLINT_MOCK_RANGE_EXIT=127

  run -1 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "fail" ]
  [ "$(output_value commits-result)" = "error" ]
  grep -q "rejected a message" "$GITHUB_STEP_SUMMARY"
  grep -q "not a problem with the commit messages" "$GITHUB_STEP_SUMMARY"
}

@test "honours the skip list only for this repository when GITHUB_REPOSITORY is unset" {
  # An unset GITHUB_REPOSITORY must fail closed, not silently disable the guard.
  export INPUT_BRANCH="sync-from-oss/main"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_HEAD_REPOSITORY="a-contributor/vcluster-pro"
  unset GITHUB_REPOSITORY
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [ "$(output_value skipped)" = "false" ]
}

# Two payloads, one rule. A CR splits the line at the runner, so a value printed
# raw forges a command outright. A %0A does not - the runner decodes an
# annotation's data for the annotation, it does not feed it back through command
# parsing - but the decoded break still tears the annotation's text out of the
# shape the raw log implies. Hence the conservative rule action.sh states and
# assert_not_on_command_line pins: untrusted values never share a line with a
# "::" command, they go on their own plain line.
PERCENT_PAYLOAD='%0A::add-mask::pwn'

@test "a CR in the pr title cannot forge a workflow command" {
  export INPUT_PR_TITLE=$'feat: x\r::stop-commands::abc'"$PERCENT_PAYLOAD"

  run -0 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line "$PERCENT_PAYLOAD"
  # Every forgery test needs this: "no forged command appeared" is trivially
  # true of a value that was never printed, so deleting the print_untrusted
  # call would satisfy the two assertions above and the defence they guard
  # would have no coverage at all.
  [[ "$output" == *'feat: x'* ]]
}

@test "a pr title starting with :: cannot forge a workflow command" {
  # The runner trims leading whitespace before matching "::", so indenting the
  # value is not enough on its own.
  export INPUT_PR_TITLE='::add-mask::0'

  run -0 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line '::add-mask::0'
  [[ "$output" == *'::add-mask::0'* ]]
}

@test "commitlint's own echo of the title cannot forge a workflow command" {
  # commitlint prints the message back, so its stdout is as hostile as the input.
  export INPUT_PR_TITLE="fix: something"
  export COMMITLINT_MOCK_STDOUT=$'validating\r::stop-commands::abc'"$PERCENT_PAYLOAD"

  run -0 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line "$PERCENT_PAYLOAD"
  [[ "$output" == *'validating'* ]]
}

@test "commitlint's range report cannot forge a workflow command" {
  # A commit body carrying a CR reaches the log through the range report, which
  # test 23 does not cover - it only exercises the title path.
  export INPUT_FROM="$BASE_SHA"
  export COMMITLINT_MOCK_STDOUT=$'linting\r::stop-commands::pwn'"$PERCENT_PAYLOAD"

  run -0 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line "$PERCENT_PAYLOAD"
  [[ "$output" == *'linting'* ]]
}

@test "shows commitlint's range report" {
  # Without this, dropping the report entirely would be invisible: the
  # contributor would see an empty group and no reason for the failure.
  export INPUT_FROM="$BASE_SHA"
  export COMMITLINT_MOCK_STDOUT="subject may not be empty"
  export COMMITLINT_MOCK_RANGE_EXIT=1

  run -1 "$SCRIPT"

  [[ "$output" == *"subject may not be empty"* ]]
}

@test "reports an unreachable range as a setup problem, not a bad message" {
  # Forgetting fetch-depth: 0 is the likeliest caller mistake here, and
  # commitlint exits 1 for it, which would otherwise read as a rejected message.
  export INPUT_FROM="0000000000000000000000000000000000000000"
  export INPUT_TO="HEAD"

  run -1 "$SCRIPT"

  [ "$(output_value commits-result)" = "error" ]
  [[ "$output" == *"fetch-depth: 0"* ]]
  # commitlint must never have been invoked for the range.
  assert_no_call_matching "--from"
}

@test "an unreachable range is still a setup problem in strict mode" {
  # Exit 2 would be a warning under --strict, so the sentinel must sit outside
  # every message-problem set.
  export INPUT_FAIL_ON_WARNINGS="true"
  export INPUT_FROM="0000000000000000000000000000000000000000"

  run -1 "$SCRIPT"

  [ "$(output_value commits-result)" = "error" ]
}

@test "writes every output when working-directory does not exist" {
  export INPUT_WORKING_DIRECTORY="$BATS_TEST_TMPDIR/nope"
  export INPUT_PR_TITLE="fix: something"

  run -1 "$SCRIPT"

  [ "$(output_value skipped)" = "false" ]
  [ "$(output_value pr-title-result)" = "error" ]
  # Not requested, so not "error".
  [ "$(output_value commits-result)" = "skipped" ]
}

@test "a CR in the branch name cannot forge a command on the skip path" {
  # The fork-ignore path routed the branch name correctly while the skip path
  # printed it raw, so the existing coverage gave false assurance.
  export INPUT_BRANCH=$'sync-from-oss/x\r::stop-commands::pwn'
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_HEAD_REPOSITORY="loft-sh/repo"
  export GITHUB_REPOSITORY="loft-sh/repo"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [ "$(output_value skipped)" = "true" ]
  assert_no_forged_commands
  [[ "$output" == *'sync-from-oss/x'* ]]
}

# The fork's repository name is the fourth channel action.sh's header calls
# hostile, and it reaches the log whenever the skip list is declined.
@test "an untrusted fork repository name cannot forge a workflow command" {
  export INPUT_BRANCH="sync-from-oss/main"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_HEAD_REPOSITORY=$'evil/repo\r::stop-commands::pwn'"$PERCENT_PAYLOAD"
  export GITHUB_REPOSITORY="loft-sh/repo"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line "$PERCENT_PAYLOAD"
  [[ "$output" == *'evil/repo'* ]]
}

@test "a branch name cannot break out of the job summary code span" {
  export INPUT_BRANCH='x`</code>**pwned**'
  export INPUT_SKIP_BRANCHES="x*"
  export INPUT_HEAD_REPOSITORY="loft-sh/repo"
  export GITHUB_REPOSITORY="loft-sh/repo"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  assert_summary_lacks '</code>'
  assert_summary_lacks '`x`'
  # The summary line has to exist, or both assertions above hold on an empty file.
  grep -q 'is exempt' "$GITHUB_STEP_SUMMARY"
}

@test "npm output cannot forge a workflow command" {
  # On a fork pull request npm is parsing the fork's own manifest.
  echo '{"devDependencies":{"@commitlint/cli":"19.8.1"}}' >package.json
  echo '{}' >package-lock.json
  export NPM_MOCK_STDOUT=$'npm error notarget\r::stop-commands::pwn'"$PERCENT_PAYLOAD"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line "$PERCENT_PAYLOAD"
  [[ "$output" == *'npm error notarget'* ]]
}

@test "keeps a non-ascii line separator out of the log" {
  # NEL, U+2028 and U+2029 are dropped, matching lib/log.sh.
  export INPUT_PR_TITLE=$'fix: x\u0085::stop-commands::pwn'

  run -0 "$SCRIPT"

  [[ "$output" != *$'\u0085'* ]]
  [[ "$output" == *'fix: x'* ]]
}

@test "does not claim a check errored when it was never requested" {
  # Range-only linting with a bad working-directory must not report on a title
  # check the caller never asked for.
  export INPUT_WORKING_DIRECTORY="$BATS_TEST_TMPDIR/nope"
  export INPUT_FROM="abc123"

  run -1 "$SCRIPT"

  [ "$(output_value commits-result)" = "error" ]
  [ "$(output_value pr-title-result)" = "skipped" ]
}

# The mirror of "warns when to is wired but from is empty": a `to` expression
# that resolved to nothing must not quietly become HEAD, or the range linted is
# not the range requested.
@test "warns when to resolves to an empty value" {
  export INPUT_FROM="$BASE_SHA"
  export INPUT_TO=""

  run -0 "$SCRIPT"

  [[ "$output" == *"'to' resolved to an empty value; linting up to HEAD"* ]]
  [ "$(output_value commits-result)" = "pass" ]
  calls | grep -q -- "--from $BASE_SHA --to HEAD"
}

# With no `from` either there is no range to lint, so the warning must not claim
# a run up to HEAD that never happened.
@test "reports an empty to and an empty from as no commits linted" {
  export INPUT_TO=""
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [[ "$output" == *"so no commits were linted"* ]]
  [[ "$output" != *"linting up to HEAD"* ]]
  [ "$(output_value commits-result)" = "skipped" ]
}

# `to` is a plausible carrier for a fork-chosen ref, and an unresolvable one
# takes the reachability path, which prints the revision back.
@test "an untrusted to cannot forge a workflow command" {
  export INPUT_FROM="$BASE_SHA"
  export INPUT_TO='x%0A::add-mask::secret'

  run -1 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line 'x%0A'
  # The revision must still be reported, or the caller cannot see which one.
  [[ "$output" == *'x%0A'* ]]
}

@test "warns when to is wired but from is empty" {
  # A green run that linted no commits at all is worse than a failure.
  export INPUT_TO="$HEAD_SHA"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [[ "$output" == *"'to' is set but 'from' is empty"* ]]
  [ "$(output_value commits-result)" = "skipped" ]
}

@test "an exempt branch is skipped even when working-directory is missing" {
  # The branch whose commits cannot be rewritten must not be failed by a
  # directory that happens not to exist on it.
  export INPUT_BRANCH="sync-from-oss/main"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_HEAD_REPOSITORY="loft-sh/repo"
  export GITHUB_REPOSITORY="loft-sh/repo"
  export INPUT_WORKING_DIRECTORY="$BATS_TEST_TMPDIR/nope"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [ "$(output_value skipped)" = "true" ]
}

@test "does not warn about forks when the branch matches no skip pattern" {
  # Otherwise every outside pull request to a repo that merely configures
  # skip-branches collects a spurious annotation.
  export INPUT_BRANCH="feat/some-contribution"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_HEAD_REPOSITORY="a-contributor/repo"
  export GITHUB_REPOSITORY="loft-sh/repo"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [ "$(output_value skipped)" = "false" ]
  [[ "$output" != *"Ignoring skip-branches"* ]]
}

@test "reports git's own error instead of blaming fetch-depth" {
  # A container job with a dubious-ownership checkout fails the revision check
  # for a reason that has nothing to do with clone depth.
  export INPUT_FROM="$BASE_SHA"
  export INPUT_WORKING_DIRECTORY="$BATS_TEST_TMPDIR"
  mkdir -p "$BATS_TEST_TMPDIR/notarepo"
  export INPUT_WORKING_DIRECTORY="$BATS_TEST_TMPDIR/notarepo"

  run -1 "$SCRIPT"

  [ "$(output_value commits-result)" = "error" ]
  [[ "$output" == *"git:"* ]]
}

@test "warns when skip-branches is set without head-repository" {
  # Otherwise a caller silently reinstates the fork bypass.
  export INPUT_BRANCH="sync-from-oss/main"
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_PR_TITLE="anything"

  run -0 "$SCRIPT"

  [[ "$output" == *"head-repository is not"* ]]
  [ "$(output_value skipped)" = "true" ]
}

@test "keeps an untrusted branch name off the workflow-command line" {
  # The runner percent-decodes ::warning:: lines and a ref may contain '%'.
  export INPUT_BRANCH='sync-from-oss/x%0A::add-mask::secret'
  export INPUT_SKIP_BRANCHES="sync-from-oss/*"
  export INPUT_HEAD_REPOSITORY="outsider/repo"
  export GITHUB_REPOSITORY="loft-sh/repo"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line 'sync-from-oss/x%0A'
  # The branch name must still be reported.
  [[ "$output" == *'sync-from-oss/x%0A'* ]]
}

# Real commitlint 19.8.1 reads a whitespace-only message as no input, prints its
# usage and exits 1 - which under --strict the classifier would call a CI
# problem, sending a contributor after an outage over a blank title.
@test "reports a whitespace-only title as a message problem, not a CI problem" {
  export INPUT_PR_TITLE="   "
  export INPUT_FAIL_ON_WARNINGS="true"

  run -1 "$SCRIPT"

  [ "$(output_value pr-title-result)" = "fail" ]
  [[ "$output" == *"whitespace only"* ]]
  # commitlint must never be handed the message, or its usage-exit lands back in
  # the classifier. The --version probe still runs, and is not a lint.
  assert_nothing_was_linted
}

@test "reports exit 1 as a genuine message problem" {
  export INPUT_PR_TITLE="bugfix: nope"
  export COMMITLINT_MOCK_TITLE_EXIT=1

  run -1 "$SCRIPT"

  [[ "$output" != *"not a problem with the commit messages"* ]]
  grep -q "Commitlint failed" "$GITHUB_STEP_SUMMARY"
}

# The gate the README recommends reads `skipped`, so that is the output worth
# forging: a rejected title reported correctly still waves the run through if a
# child got the last word on it.
@test "a commitlint from the checkout cannot forge the skipped output" {
  install_output_forging_commitlint
  export INPUT_PR_TITLE="bugfix: nope"
  export COMMITLINT_MOCK_TITLE_EXIT=1

  run -1 "$SCRIPT"

  # output_value takes the last occurrence, which is how the runner resolves a
  # repeated key, so this fails if the script does not write after the child.
  [ "$(output_value skipped)" = "false" ]
  [ "$(output_value pr-title-result)" = "fail" ]
  # The forged line must really be in the file, or the test proves nothing.
  grep -qx 'skipped=true' "$GITHUB_OUTPUT"
}

@test "prefers a commitlint already present in node_modules" {
  install_local_commitlint
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [[ "$output" == *"Using commitlint from node_modules"* ]]
  assert_no_call_matching "^npm "
  assert_no_call_matching "^npx "
}

@test "installs from the lockfile when the repo pins commitlint" {
  echo '{"devDependencies":{"@commitlint/cli":"19.8.1"}}' >package.json
  echo '{}' >package-lock.json
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep -q "^npm ci"
  [[ "$output" == *"commitlint dependency"* ]]
}

@test "installs a shared config package the npx fallback could not provide" {
  # A config extending @commitlint/config-conventional needs that package
  # present; npx only ever brings the CLI, so commitlint would die on
  # MODULE_NOT_FOUND and the contributor would be told their message is bad.
  echo '{"devDependencies":{"@commitlint/config-conventional":"19.8.1"}}' >package.json
  echo '{}' >package-lock.json
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep -q "^npm ci"
}

@test "does not run lifecycle scripts when installing from a lockfile" {
  # On a fork pull request this installs the fork's own package.json.
  echo '{"devDependencies":{"@commitlint/cli":"19.8.1"}}' >package.json
  echo '{}' >package-lock.json
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep "^npm ci" | grep -q -- "--ignore-scripts"
}

@test "does not run lifecycle scripts when installing without a lockfile" {
  # The no-lockfile branch is the one a fork can reach just by omitting the
  # lockfile, so it needs the same guarantee as the npm ci branch.
  echo '{"devDependencies":{"@commitlint/cli":"19.8.1"}}' >package.json
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep "^npm install" | grep -q -- "--ignore-scripts"
}

@test "uses npm install when the repo pins commitlint without a lockfile" {
  echo '{"devDependencies":{"@commitlint/cli":"19.8.1"}}' >package.json
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep -q "^npm install"
}

@test "falls back to npx when the repo pins nothing" {
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep -q "^npx --yes @commitlint/cli@19.8.1"
}

@test "falls back to npx when the pinned install produces no binary" {
  echo '{"devDependencies":{"@commitlint/cli":"19.8.1"}}' >package.json
  echo '{}' >package-lock.json
  export NPM_MOCK_FAIL=1
  export INPUT_PR_TITLE="fix: something"

  # A broken lockfile must not take the whole check down with it.
  run -0 "$SCRIPT"

  calls | grep -q "^npx --yes @commitlint/cli@19.8.1"
}

@test "honours a custom commitlint version" {
  export INPUT_COMMITLINT_VERSION="20.1.0"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep -q "^npx --yes @commitlint/cli@20.1.0"
}

@test "passes the config path through" {
  export INPUT_CONFIG_PATH="ci/commitlint.config.js"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep -q -- "--config ci/commitlint.config.js"
}

@test "passes --strict when warnings should fail" {
  export INPUT_FAIL_ON_WARNINGS="true"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  calls | grep -q -- "--strict"
}

@test "does not pass --strict by default" {
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  assert_no_call_matching "--strict"
}

# "True" is the plausible typo, and without the warning it reads as a green run
# to a caller who believes warnings are fatal.
@test "warns when fail-on-warnings is neither true nor false" {
  export INPUT_FAIL_ON_WARNINGS="True"
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [[ "$output" == *"fail-on-warnings is neither"* ]]
  [[ "$output" == *"fail-on-warnings: True"* ]]
  assert_no_call_matching "--strict"
}

# An expression that resolves to nothing is the mis-wiring most likely to reach
# this input, and the runner keeps a supplied-but-empty input empty rather than
# falling back to the manifest default - so the script has to warn about it too.
@test "warns when fail-on-warnings is passed as an empty value" {
  export INPUT_FAIL_ON_WARNINGS=""
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  [[ "$output" == *"fail-on-warnings is neither"* ]]
  assert_no_call_matching "--strict"
}

@test "stays quiet about fail-on-warnings when it is a boolean" {
  local value
  for value in true false; do
    : >"$GITHUB_OUTPUT"
    export INPUT_FAIL_ON_WARNINGS="$value"
    export INPUT_PR_TITLE="fix: something"

    run -0 "$SCRIPT"

    [[ "$output" != *"fail-on-warnings is neither"* ]]
  done
}

@test "keeps a malformed fail-on-warnings off the workflow-command line" {
  export INPUT_FAIL_ON_WARNINGS='yes%0A::add-mask::secret'
  export INPUT_PR_TITLE="fix: something"

  run -0 "$SCRIPT"

  assert_no_forged_commands
  assert_not_on_command_line 'yes%0A'
  # The value must still be reported somewhere, or the warning is useless.
  [[ "$output" == *'yes%0A'* ]]
}

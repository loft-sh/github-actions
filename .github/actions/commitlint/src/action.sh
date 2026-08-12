#!/usr/bin/env bash
# Lint commit messages and pull request titles with commitlint.
#
# The config always comes from the calling repository, never from here: this
# action decides *what* to lint and *when to skip*, the repository decides what
# the rules are.
#
# Trust model: the config, and any node_modules/.bin/commitlint, are read from
# the checkout, which on a fork pull request the author controls. A fork can
# weaken the config and get a pass. This is a contributor-facing aid on fork
# PRs, not an enforcement boundary; it enforces on branches in the repository
# itself. See the README.
#
# Both checks run to completion before the script fails, so a contributor gets
# every problem in one run rather than discovering the second one after fixing
# the first.
#
# Env:
#   INPUT_PR_TITLE            Message to lint on its own. Empty skips.
#   INPUT_FROM, INPUT_TO      Commit range to lint. Empty INPUT_FROM skips;
#                             empty INPUT_TO warns and falls back to HEAD.
#   INPUT_SKIP_BRANCHES       Comma-separated globs; a match exits 0 early.
#   INPUT_BRANCH              Branch name matched against INPUT_SKIP_BRANCHES.
#   INPUT_HEAD_REPOSITORY     Repo the branch lives on; a fork disables skipping.
#   INPUT_CONFIG_PATH         Config path; empty uses commitlint discovery.
#   INPUT_WORKING_DIRECTORY   Directory to run in. Default ".".
#   INPUT_COMMITLINT_VERSION  Version used when the repo pins none.
#   INPUT_FAIL_ON_WARNINGS    "true" treats warnings as failures.

set -euo pipefail

PR_TITLE="${INPUT_PR_TITLE:-}"
FROM="${INPUT_FROM:-}"
TO="${INPUT_TO-HEAD}"
SKIP_BRANCHES="${INPUT_SKIP_BRANCHES:-}"
BRANCH="${INPUT_BRANCH:-}"
HEAD_REPOSITORY="${INPUT_HEAD_REPOSITORY:-}"
CONFIG_PATH="${INPUT_CONFIG_PATH:-}"
WORKING_DIRECTORY="${INPUT_WORKING_DIRECTORY:-.}"
# No literal fallback here on purpose. action.yml carries the pin and is the
# copy Renovate keeps current; a second one in this file would be the version
# that actually runs whenever the input resolves to empty, and it would sit a
# bump behind with nothing to notice. An empty value is handled where it is
# used, in resolve_commitlint.
COMMITLINT_VERSION="${INPUT_COMMITLINT_VERSION:-}"
# "-" rather than ":-": the composite always exports this variable, and the
# runner does not apply an input's default to an input that was passed as an
# empty string. So an empty value here is a caller expression that resolved to
# nothing, which is precisely what warn_unless_boolean has to surface, and
# ":-" would rewrite it to "false" before the warning could see it.
FAIL_ON_WARNINGS="${INPUT_FAIL_ON_WARNINGS-false}"

# Resolved by resolve_commitlint into the argv of a runnable commitlint.
COMMITLINT_CMD=()

log() { printf '%s\n' "$*"; }

# Every externally-controlled string printed by this script goes through here.
# The hostile channels are the pull request title, the branch name, the fork's
# repository name, and commitlint's own stdout, which echoes the message back.
#
# The runner ends a log line on CR as well as LF, so a raw CR inside a title
# splits the output and a following "::" starts a workflow command at column 0.
# It also trims leading whitespace before matching "::", so indenting untrusted
# text is not a defence on its own - a title that merely starts with "::" is
# parsed straight off an indented line.
#
# So: strip the characters that can split a line, then prefix every line with a
# non-whitespace marker, which is what actually makes a leading "::" unparseable.
#
# The companion rule, enforced by inspection: no untrusted value is ever
# interpolated into a "::" annotation line, because those are percent-decoded
# and would need escaping as well. Untrusted values go on their own plain line.
#
# LC_ALL=C so an inherited locale cannot defeat the class matching, and -cd
# rather than -d so everything outside printable ASCII plus LF is dropped. That
# also covers NEL, U+2028 and U+2029, which a runner or terminal may treat as
# breaks. This mirrors auto-approve-bot-prs/src/lib/log.sh, which states the
# repository's rule; the logic is duplicated rather than shared because actions
# here are versioned independently and that lib is action-local.
print_untrusted() {
  printf '%s\n' "$1" | LC_ALL=C tr -cd '\040-\176\012' | sed 's/^/| /'
}

# For untrusted text interpolated into the job summary, which is markdown rather
# than a log stream. Strips what would break out of a code span or open a tag.
scrub() {
  printf '%s' "$1" | LC_ALL=C tr -cd '\040-\176' | tr -d '`<>'
}

emit_output() {
  local name="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
  fi
}

# Every exit path that runs after a child process could have started writes all
# three outputs through here, and nothing writes them earlier.
#
# $GITHUB_OUTPUT is a path in the environment, the file is append-only, and the
# runner resolves a repeated key to its last occurrence. Every child inherits
# it: commitlint, npm, npx, and on a repository that pins its own, a
# node_modules/.bin/commitlint that came from the checkout. So an output written
# before those run can be appended over by them, and "skipped" is the one worth
# forging - the gate this action's README recommends waves a run through on it.
# Writing last is what makes the script's value the one that survives.
emit_results() {
  emit_output skipped "$1"
  emit_output pr-title-result "$2"
  emit_output commits-result "$3"
}

emit_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# True when $BRANCH matches any comma-separated glob in $SKIP_BRANCHES.
# Patterns are globs, not regexes, so "sync-from-oss/*" reads the way an
# author expects.
#
# A branch name on a fork PR is chosen freely by the pull request author, so
# honouring the skip list there would let anyone opt out of linting by naming
# their branch after an exempt pattern. When head-repository is supplied and
# is not this repository, the skip list is ignored.
branch_matches_skip_list() {
  # printf must emit a trailing newline: without it `read` hits EOF on the
  # last pattern and the loop body never sees it.
  local pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254  # the pattern is meant to glob
    case "$BRANCH" in
      $pattern) return 0 ;;
    esac
  done < <(printf '%s\n' "$SKIP_BRANCHES" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

  return 1
}

branch_is_skipped() {
  [ -n "$BRANCH" ] && [ -n "$SKIP_BRANCHES" ] || return 1

  # Match first, so the warnings below only fire when the skip list would
  # actually have exempted something. Warning on every fork pull request to a
  # repo that merely configures skip-branches is noise on an action whose
  # audience is contributors.
  branch_matches_skip_list || return 1

  if [ -z "$HEAD_REPOSITORY" ]; then
    log "::warning::This branch matches skip-branches and was not linted, but head-repository is not set. On a fork pull request the branch name is chosen by its author, so the skip list can be used to opt out of linting. Pass head-repository to close that."
    return 0
  fi

  # No guard on GITHUB_REPOSITORY being set: an unset one compares unequal and
  # so ignores the skip list, which is the safe direction to fail.
  if [ "$HEAD_REPOSITORY" != "${GITHUB_REPOSITORY:-}" ]; then
    log "::warning::Ignoring skip-branches: this branch lives on a fork, whose branch names are chosen by the pull request author."
    print_untrusted "fork: ${HEAD_REPOSITORY}"
    print_untrusted "branch: ${BRANCH}"
    return 1
  fi

  return 0
}

# Prefer a commitlint the calling repository already pins: running a different
# version than the repo's own contributors run locally would produce results
# nobody can reproduce.
resolve_commitlint() {
  if [ -x node_modules/.bin/commitlint ]; then
    log "Using commitlint from node_modules"
    COMMITLINT_CMD=(node_modules/.bin/commitlint)
    return
  fi

  # Match any commitlint-related dependency, not just the CLI: a config that
  # extends a shared package needs that package present, and the npx fallback
  # below only ever brings the CLI. This catches @commitlint/*, @scope/commitlint
  # -config and commitlint-config-* alike. A parser preset whose package name
  # contains no "commitlint" at all is the known gap, documented in the README.
  if [ -f package.json ] && grep -qi 'commitlint' package.json; then
    log "Repository declares a commitlint dependency; installing it"
    # --ignore-scripts: on a fork pull request this installs the fork's own
    # package.json, and commitlint needs no lifecycle scripts to run.
    #
    # A broken install must not take the check down with it - fall through to
    # the pinned fallback version below and still lint something.
    # npm's output is untrusted too: on a fork pull request it is parsing the
    # fork's manifest and echoes strings from it back on failure.
    local install_out install_status=0
    if [ -f package-lock.json ]; then
      install_out=$(npm ci --no-audit --no-fund --ignore-scripts 2>&1) || install_status=$?
    else
      install_out=$(npm install --no-audit --no-fund --ignore-scripts 2>&1) || install_status=$?
    fi
    [ -n "$install_out" ] && print_untrusted "$install_out"
    if [ "$install_status" -ne 0 ]; then
      log "::warning::The commitlint install failed; falling back to the pinned version."
      print_untrusted "fallback version: ${COMMITLINT_VERSION}"
    fi

    if [ -x node_modules/.bin/commitlint ]; then
      COMMITLINT_CMD=(node_modules/.bin/commitlint)
      return
    fi
  fi

  # Only reachable when a caller passed the input as an empty string, since
  # action.yml always supplies a value otherwise. Fetching "@commitlint/cli@"
  # would fail with a message about the package rather than about the wiring.
  if [ -z "$COMMITLINT_VERSION" ]; then
    log "::warning::commitlint-version resolved to an empty value; using the latest published @commitlint/cli. Check the expression wired into it."
    COMMITLINT_CMD=(npx --yes "@commitlint/cli")
    return
  fi

  log "Using @commitlint/cli, version:"
  print_untrusted "${COMMITLINT_VERSION}"
  COMMITLINT_CMD=(npx --yes "@commitlint/cli@${COMMITLINT_VERSION}")
}

# Only the exact string "true" turns warnings into failures, and anything else
# both drops --strict and flips the exit-code classifier below to its non-strict
# table. So "True", "yes" or a mis-wired expression gives a caller who believes
# warnings are fatal a green run, with no sign anywhere that the input was read
# differently than they wrote it. Warn rather than fail: the check itself is
# still doing useful work, and taking it down over this input would be worse.
warn_unless_boolean() {
  case "$FAIL_ON_WARNINGS" in
    true | false) return 0 ;;
  esac

  log '::warning::fail-on-warnings is neither "true" nor "false", so warnings will not fail the check. An empty value means the expression wired into it resolved to nothing.'
  print_untrusted "fail-on-warnings: ${FAIL_ON_WARNINGS}"
}

# Every invocation shares the config and strictness flags.
run_commitlint() {
  local flags=()
  [ -n "$CONFIG_PATH" ] && flags+=(--config "$CONFIG_PATH")
  [ "$FAIL_ON_WARNINGS" = "true" ] && flags+=(--strict)

  "${COMMITLINT_CMD[@]}" ${flags[@]+"${flags[@]}"} "$@"
}

# Telling a contributor their commit message is wrong because npm was down
# would send them chasing a problem they do not have, so a commitlint that
# never ran is reported differently from one that ran and found problems.
#
# Which exit codes mean "the message has problems" depends on --strict: without
# it commitlint returns 1, with it 2 for warnings and 3 for errors and never 1.
#
# So exit 1 under --strict means commitlint never got as far as judging a
# message, and is deliberately not in the strict list. Measured against 19.8.1
# the cases are an unresolvable `extends`, and a message the CLI reads as no
# input at all - which is why a whitespace-only pr-title is rejected in main()
# before it can get here and be reported as a CI problem. A --from revision
# missing from a shallow clone exits 1 too, but range_is_reachable catches that
# one first, so it never reaches this classifier.
#
# Without --strict the same setup failures are indistinguishable from a bad
# message, since both exit 1. That case is a genuine heuristic gap.
message_problem_exit_codes() {
  if [ "$FAIL_ON_WARNINGS" = "true" ]; then
    printf '2 3'
  else
    printf '1'
  fi
}

is_infrastructure_failure() {
  local status="$1" code
  [ "$status" -eq 0 ] && return 1

  for code in $(message_problem_exit_codes); do
    [ "$status" -eq "$code" ] && return 1
  done

  return 0
}

# Fail fast on a commitlint that cannot run at all, so the per-message results
# below only ever report on messages.
verify_commitlint_runs() {
  local status=0
  "${COMMITLINT_CMD[@]}" --version >/dev/null 2>&1 || status=$?

  if [ "$status" -ne 0 ]; then
    log "::error::commitlint could not be run (exit ${status}). This is a CI or network problem, not a problem with the commit messages."
    emit_summary "### Commitlint could not run"
    emit_summary ""
    emit_summary "commitlint failed to start (exit \`${status}\`). This is a CI or network problem, not a problem with the commit messages."
    return 1
  fi
}

lint_pr_title() {
  log "::group::Linting pull request title"
  print_untrusted "$PR_TITLE"

  # commitlint echoes the message back on its own stdout, so its output is just
  # as attacker-controlled as the title. Capture it and print it through
  # print_untrusted rather than letting the child write to the log directly.
  local status=0 out
  out=$(printf '%s' "$PR_TITLE" | run_commitlint 2>&1) || status=$?
  [ -n "$out" ] && print_untrusted "$out"
  log "::endgroup::"

  return "$status"
}

# Forgetting fetch-depth: 0 is the likeliest caller mistake with range linting,
# and commitlint exits 1 for an unreachable revision - indistinguishable from a
# rejected message without --strict. Check reachability first so it is reported
# as the setup failure it is.
#
# The code must sit outside every message-problem set - 1 non-strict, 2 and 3
# under --strict - or the classifier would read it back as a bad message in one
# of the two modes.
UNREACHABLE_RANGE_EXIT=64

range_is_reachable() {
  local rev err
  for rev in "$FROM" "$TO"; do
    if ! err=$(git cat-file -e "${rev}^{commit}" 2>&1); then
      log "::error::A revision in the range could not be resolved. Usually this means the history is shallow - check out with fetch-depth: 0. If git reports something else below, that is the real cause."
      print_untrusted "unresolved revision: ${rev}"
      [ -n "$err" ] && print_untrusted "git: ${err}"
      return 1
    fi
  done
}

lint_range() {
  log "::group::Linting commits"
  print_untrusted "${FROM}..${TO}"

  if ! range_is_reachable; then
    log "::endgroup::"
    return "$UNREACHABLE_RANGE_EXIT"
  fi

  local status=0 out
  out=$(run_commitlint --from "$FROM" --to "$TO" 2>&1) || status=$?
  [ -n "$out" ] && print_untrusted "$out"
  log "::endgroup::"

  return "$status"
}

main() {
  # The skip decision reads only inputs, so it comes before the cd. An exempt
  # branch must not be failed by a working-directory that happens not to exist
  # on it - that is exactly the branch whose commits cannot be rewritten.
  if branch_is_skipped; then
    log "Branch matches skip-branches; nothing linted."
    print_untrusted "branch: ${BRANCH}"
    print_untrusted "skip-branches: ${SKIP_BRANCHES}"
    emit_results true skipped skipped
    emit_summary "Commitlint skipped: branch \`$(scrub "$BRANCH")\` is exempt."
    return 0
  fi
  warn_unless_boolean

  local title_result=skipped commits_result=skipped failed=0 infrastructure=0

  if ! cd "$WORKING_DIRECTORY" 2>/dev/null; then
    log "::error::working-directory does not exist or is not a directory."
    print_untrusted "working-directory: ${WORKING_DIRECTORY}"
    # "error" means a requested check could not run. A check the caller never
    # asked for stays "skipped", or a caller reports on work it never wanted.
    [ -n "$PR_TITLE" ] && title_result=error
    [ -n "$FROM" ] && commits_result=error
    emit_results false "$title_result" "$commits_result"
    return 1
  fi

  # The reason `to` is expanded with "-" rather than ":-": an expression that
  # resolved to nothing would otherwise be rewritten to HEAD in silence, and the
  # range linted would not be the range the caller asked for. HEAD is still the
  # right thing to fall back to - an empty revision fails the reachability check
  # as if the clone were shallow, which is a worse answer than a warning.
  #
  # What to say about it depends on `from`: with `from` empty as well, no range
  # is linted at all, and claiming a run up to HEAD would describe work that
  # never happened. The rewrite also has to come after both, since it is what
  # makes an empty `to` indistinguishable from an unset one further down.
  if [ -z "$TO" ]; then
    if [ -n "$FROM" ]; then
      log "::warning::'to' resolved to an empty value; linting up to HEAD instead. Check the expression wired into 'to'."
    else
      log "::warning::'to' resolved to an empty value and 'from' is empty too, so no commits were linted. Check the expressions wired into them."
    fi
    TO=HEAD
  fi

  # `to` defaults to HEAD, so a non-default `to` with an empty `from` is a
  # caller whose `from` expression resolved to nothing - a green run that linted
  # no commits at all.
  if [ -z "$FROM" ] && [ "$TO" != "HEAD" ]; then
    log "::warning::'to' is set but 'from' is empty, so no commits were linted. Check the expression wired into 'from'."
  fi

  if [ -z "$PR_TITLE" ] && [ -z "$FROM" ]; then
    log "::error::Nothing to lint: set pr-title, or from and to, or both."
    emit_results false "$title_result" "$commits_result"
    return 1
  fi

  resolve_commitlint

  if ! verify_commitlint_runs; then
    # The requested checks were never judged. Report that as "error", the value
    # action.yml documents for a commitlint that could not run, rather than
    # "skipped", which a caller cannot tell from "never asked for".
    [ -n "$PR_TITLE" ] && title_result=error
    [ -n "$FROM" ] && commits_result=error
    emit_results false "$title_result" "$commits_result"
    return 1
  fi

  local status
  if [ -n "${PR_TITLE//[[:space:]]/}" ]; then
    status=0
    lint_pr_title || status=$?
    if [ "$status" -eq 0 ]; then
      title_result=pass
    elif is_infrastructure_failure "$status"; then
      # Not "fail": the message was never judged, and a caller branching on
      # this output must not tell the author their message is wrong.
      title_result=error
      failed=1
      infrastructure=1
    else
      title_result=fail
      failed=1
    fi
  elif [ -n "$PR_TITLE" ]; then
    # commitlint reads a whitespace-only message as no input at all: it prints
    # its usage and exits 1, which under --strict falls outside the
    # message-problem set and would be reported as a CI outage the contributor
    # cannot act on. The message really is blank, which is a problem with the
    # message, so say that rather than handing it to commitlint.
    log "::error::pr-title is whitespace only, so there is no message to lint."
    print_untrusted "pr-title: ${PR_TITLE}"
    title_result=fail
    failed=1
  fi

  if [ -n "$FROM" ]; then
    status=0
    lint_range || status=$?
    if [ "$status" -eq 0 ]; then
      commits_result=pass
    elif is_infrastructure_failure "$status"; then
      commits_result=error
      failed=1
      infrastructure=1
    else
      commits_result=fail
      failed=1
    fi
  fi

  emit_results false "$title_result" "$commits_result"

  if [ "$failed" -eq 1 ]; then
    # One table covering both checks: a run where one check found a real problem
    # and the other crashed has to report both, or the contributor is told "this
    # is a CI problem" while a genuine message problem sits in the outputs.
    emit_summary "### Commitlint failed"
    emit_summary ""
    emit_summary "| check | result |"
    emit_summary "| --- | --- |"
    emit_summary "| pull request title | ${title_result} |"
    emit_summary "| commits | ${commits_result} |"
    emit_summary ""

    if [ "$infrastructure" -eq 1 ]; then
      emit_summary "\`error\` means commitlint could not run for that check. That is a CI problem, not a problem with the commit messages."
      log "::error::commitlint could not run for at least one check (title: ${title_result}, commits: ${commits_result})"
    fi

    if [ "$title_result" = "fail" ] || [ "$commits_result" = "fail" ]; then
      emit_summary "\`fail\` means commitlint ran and rejected a message. See the step log for the offending messages."
      log "::error::commitlint found problems (title: ${title_result}, commits: ${commits_result})"
    fi

    return 1
  fi

  emit_summary "Commitlint passed (title: ${title_result}, commits: ${commits_result})."
  log "commitlint passed (title: ${title_result}, commits: ${commits_result})"
  return 0
}

# Only run when executed, so the tests can source this file for unit checks.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi

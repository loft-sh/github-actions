#!/usr/bin/env bash
# start mode: decide whether this comment is a command we should act on, and if
# so open a check-run on the pull request's head commit.
#
# Two API calls, and no more. Deduplicating repeated commands is left to the
# caller's `concurrency` group (see the README): GitHub already supersedes an
# older run for the same key, and a superseded job still runs the caller's
# `always()` finish job, which closes its check. Doing it here instead meant
# listing checks, resolving the run behind each one, and closing orphans, which
# is three more calls and a state machine whose failure modes all end in
# starting a duplicate build.
#
# Inputs (env):
#   INPUT_COMMAND             command word to match, e.g. "/test-e2e"
#   INPUT_COMMENT_BODY        github.event.comment.body
#   INPUT_COMMENT_AUTHOR      github.event.comment.user.login
#   INPUT_AUTHOR_ASSOCIATION  github.event.comment.author_association
#   INPUT_PR_NUMBER           github.event.issue.number
#   INPUT_REPO                owner/name
#   INPUT_CHECK_NAME_PREFIX   prefix for the check-run name
#   INPUT_RUN_ID              github.run_id, used for the details link
#   INPUT_SERVER_URL          github.server_url
#   GH_TOKEN                  token for gh
set -euo pipefail

# shellcheck source=.github/actions/comment-triggered-check/src/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command_word="${INPUT_COMMAND:-/test-e2e}"
comment_body="${INPUT_COMMENT_BODY:-}"
comment_author="${INPUT_COMMENT_AUTHOR:-}"
association="${INPUT_AUTHOR_ASSOCIATION:-}"
pr_number="${INPUT_PR_NUMBER:-}"
repo="${INPUT_REPO:?INPUT_REPO required}"
prefix="${INPUT_CHECK_NAME_PREFIX:-e2e}"
run_id="${INPUT_RUN_ID:-}"
server_url="${INPUT_SERVER_URL:-https://github.com}"

matched=false
args=""
filter=""
should_run=false
reason=""
head_sha=""
head_ref=""
base_ref=""
concurrency_key=""
name=""
check_run_id=""

# Emitted on every path, so a caller never reads an undefined output.
finish_and_exit() {
  emit "matched" "$matched"
  emit "args" "$args"
  emit "filter" "$filter"
  emit "should-run" "$should_run"
  emit "reason" "$reason"
  emit "head-sha" "$head_sha"
  emit "head-ref" "$head_ref"
  emit "base-ref" "$base_ref"
  emit "concurrency-key" "$concurrency_key"
  emit "check-name" "$name"
  emit "check-run-id" "$check_run_id"
  exit 0
}

# gh_json <path> — body on stdout, non-zero when the call failed.
# Deliberately does NOT collapse a failure into an empty object: every caller
# here has to tell "the API answered" apart from "we have no idea", because
# guessing in the second case is how a command silently does the wrong thing.
gh_json() {
  local body
  body="$(gh api "$@" 2>/dev/null)" || return 1
  printf '%s' "$body"
}

# --- 1. Is this a command at all? -------------------------------------------
# The workflow fires on every comment in the repository, so this is the path
# almost every invocation takes. Stay quiet, and touch no API.
if ! args="$(parse_command "$command_word" "$comment_body")"; then
  echo "comment is not a ${command_word} command, nothing to do"
  args=""
  finish_and_exit
fi
matched=true

if [[ -z "$pr_number" ]]; then
  reason="not-a-pull-request"
  echo "::notice::${command_word} is only available on pull requests"
  finish_and_exit
fi

filter="$(normalize_filter "$args")"
if [[ -z "$filter" ]]; then
  reason="empty-filter"
  echo "::notice::${command_word} needs a label filter, for example \`${command_word} snapshots\`"
  finish_and_exit
fi

# Refused here rather than by the caller, so a filter that would escape the
# caller's guards never reaches a dispatch or a check-run.
if ! filter_is_balanced "$filter"; then
  reason="malformed-filter"
  echo "::notice::${command_word} filter has unbalanced parentheses: ${filter}"
  finish_and_exit
fi

# --- 2. Authorize the commenter ---------------------------------------------
# From the event payload, so no API call and no token scope to get wrong. It is
# coarser than the collaborator endpoint: a read-only collaborator reads as
# COLLABORATOR and would pass. On a same-repo-only command in an internal
# repository the cost of that is runner time, not access.
if ! is_authorized_association "$association"; then
  reason="insufficient-permission"
  echo "::notice::${comment_author} (${association:-unknown}) cannot run ${command_word}; it needs repository access"
  finish_and_exit
fi

# --- 3. Resolve the pull request --------------------------------------------
# The event carries no head SHA and no base ref: an issue_comment run is on the
# default branch, so both have to come from the API. Getting the base ref wrong
# is not cosmetic. A caller resolving an OSS chart branch from it would pair a
# PR-head image with a main-line chart (ENGQA-1088).
if ! pr_json="$(gh_json "repos/${repo}/pulls/${pr_number}")"; then
  reason="pull-request-unreadable"
  echo "::warning::could not read ${repo}#${pr_number}; not starting a run"
  finish_and_exit
fi

head_sha="$(printf '%s' "$pr_json" | jq -r '.head.sha // ""')"
# The branch name, not just the commit. A caller that hands the work to a
# non-privileged run needs it: `gh workflow run --ref` takes a branch or tag,
# never a SHA.
head_ref="$(printf '%s' "$pr_json" | jq -r '.head.ref // ""')"
base_ref="$(printf '%s' "$pr_json" | jq -r '.base.ref // ""')"
head_repo="$(printf '%s' "$pr_json" | jq -r '.head.repo.full_name // ""')"
pr_state="$(printf '%s' "$pr_json" | jq -r '.state // ""')"

if [[ -z "$head_sha" || -z "$head_ref" || -z "$base_ref" ]]; then
  reason="pull-request-unreadable"
  echo "::warning::${repo}#${pr_number} returned no head SHA, head ref or base ref; not starting a run"
  finish_and_exit
fi

if [[ "$pr_state" != "open" ]]; then
  reason="pull-request-closed"
  echo "::notice::${repo}#${pr_number} is ${pr_state}; not starting a run"
  finish_and_exit
fi

# Fork check, before the caller checks anything out. This trigger is privileged:
# it runs from the default branch of the base repository with its secrets and a
# write token, so a workflow that fetches and runs fork code hands those to a
# stranger. A security boundary, not a convenience limit.
if [[ "$head_repo" != "$repo" ]]; then
  reason="fork"
  echo "::notice::${command_word} is not available on pull requests from forks"
  finish_and_exit
fi

should_run=true
name="$(check_name "$prefix" "$filter")"
concurrency_key="$(concurrency_key "$filter")"

# --- 4. Open the check-run ---------------------------------------------------
# On the resolved head SHA, never on github.sha: for issue_comment that is the
# default branch, so a check created there is invisible on the pull request.
#
# The run link goes in the summary, not only in details_url. GitHub overrides
# details_url for check-runs owned by the github-actions app, so "View details"
# lands on the check-run's own page and never reaches the logs. Verified in the
# integration repo: details_url came back equal to html_url on every check-run,
# on create and on update alike. The summary is stored verbatim, so it is the
# only link that survives. details_url stays because a real GitHub App would
# have it honoured, and because it costs nothing.
summary="Requested by @${comment_author} with \`${command_word} ${filter}\`."
if [[ -n "$run_id" ]]; then
  summary="${summary}"$'\n\n'"[View the run](${server_url}/${repo}/actions/runs/${run_id})"
fi

if ! created="$(gh_json --method POST "repos/${repo}/check-runs" \
  -f "name=${name}" \
  -f "head_sha=${head_sha}" \
  -f "status=in_progress" \
  -f "details_url=${server_url}/${repo}/actions/runs/${run_id}" \
  -f "output[title]=Running" \
  -f "output[summary]=${summary}")"; then
  reason="check-run-not-created"
  should_run=false
  echo "::warning::could not create the check-run; not starting a run"
  finish_and_exit
fi

if ! check_run_id="$(printf '%s' "$created" | jq -r '
  if type == "object" and ((.id // null) | type) == "number"
  then .id
  else ""
  end
' 2>/dev/null)"; then
  reason="check-run-not-created"
  should_run=false
  echo "::warning::the check-run create returned an unreadable response; not starting a run"
  finish_and_exit
fi

# A create that returned no id leaves a check-run nothing can ever close, so
# treat it as a failed create rather than starting a run that cannot report.
if [[ -z "$check_run_id" ]]; then
  reason="check-run-not-created"
  should_run=false
  echo "::warning::the check-run create returned no id; not starting a run"
  finish_and_exit
fi

echo "::notice::started ${name} on ${head_sha}"
finish_and_exit

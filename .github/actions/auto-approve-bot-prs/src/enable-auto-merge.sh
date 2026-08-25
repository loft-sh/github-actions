#!/usr/bin/env bash
# Merges the PR. Exits non-zero when a requested merge cannot be performed or
# queued; successful merges, accepted queue requests and benign re-runs exit 0.
#
# A plain merge is attempted FIRST, and `--auto` is only the fallback. By the
# time this runs the action has already waited for every other check to go green
# (wait-for-ci.sh) and approved the PR, so there is normally nothing left for
# GitHub's auto-merge queue to wait on. `--auto` additionally requires the
# repository's allow_auto_merge setting, which is invisible from here and turns
# the merge into a silent no-op when it is off - and a merge that never happens
# strands whatever is waiting on it (the vcluster-release orchestrator blocks on
# exactly this merge during a legacy release cut).
#
# `--auto` still has a job: a required check that registered AFTER the CI wait
# declared green legitimately refuses a merge right now but can complete later.
# Queueing is the right answer there, so a refused plain merge degrades to it.
#
# Approval-only runs never invoke this script. Once a caller requests a merge,
# an approved-and-unmerged PR is a failed automation and must red-X the caller's
# job instead of repeating the silent stall this action is meant to prevent.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, PR_HEAD_SHA,
#               MERGE_METHOD
# Optional env: MERGE_WHEN_BLOCKED (default false), MERGE_RETRY_SLEEP_SECONDS
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${PR_HEAD_SHA:?PR_HEAD_SHA required}"
: "${MERGE_METHOD:?MERGE_METHOD required}"

# Every interpolated value below is externally controlled — gh's output is
# GitHub's, and merge-method is the calling workflow's — so all of them are
# sanitized before reaching a log line. See lib/log.sh for why a bare CR in one
# of them is enough to forge a `::error::` annotation.
# shellcheck source=.github/actions/auto-approve-bot-prs/src/lib/log.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh"

case "$MERGE_METHOD" in
  squash|merge|rebase) ;;
  *)
    echo "::error::Invalid merge method '$(safe "$MERGE_METHOD")'; PR #${PR_NUMBER} was approved but not merged"
    exit 1
    ;;
esac

# One bounded retry per merge call. Without it a single transient blip is
# escalated identically to a permanent policy refusal, and the ::error:: below
# then ships confident remediation ("check branch protection…") that is simply
# wrong for a transient cause. Secondary rate limiting is a live risk here rather
# than theoretical: by this point the action has already made up to 90 CI polls,
# up to 10 mergeability polls and the approval call, and both merge attempts
# would otherwise fire back-to-back with no delay, so one blip can take out both.
# This mirrors the retry discipline the CI wait and the mergeability poll already
# apply. Never fails: the caller decides what a non-zero merge means.
# The bypass path merges past the review requirement, so it must not run when the
# approval never landed. Unset means success, keeping direct callers unchanged.
if [ "${MERGE_WHEN_BLOCKED:-false}" = "true" ] && [ "${APPROVAL_OUTCOME:-success}" != "success" ]; then
  echo "::error::PR #${PR_NUMBER} was NOT merged: merge-when-blocked needs a recorded approval, and the approve step reported '$(safe "${APPROVAL_OUTCOME:-}")'. Anything waiting on this merge will stall until the approval lands."
  exit 1
fi

MERGE_RETRY_SLEEP="${MERGE_RETRY_SLEEP_SECONDS:-5}"
try_merge() {
  local out rc
  if out=$("$@" 2>&1); then printf '%s' "$out"; return 0; fi
  # Retry blind rather than classifying the error: gh's text is not a stable
  # API, and a permanent refusal costs only one extra call and one sleep.
  sleep "$MERGE_RETRY_SLEEP"
  out=$("$@" 2>&1) && { printf '%s' "$out"; return 0; }
  rc=$?
  printf '%s' "$out"
  return "$rc"
}

if direct_err=$(try_merge gh pr merge "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" \
  --"$MERGE_METHOD" --match-head-commit "$PR_HEAD_SHA"); then
  echo "Merged PR #${PR_NUMBER} (${MERGE_METHOD})"
  exit 0
fi

# A refused plain merge is not automatically a problem: on a re-run the PR is
# often already merged, and a PR closed unmerged is a human decision. Establish
# which it is before escalating, so the ::error:: below keeps meaning something.
pr_state=$(gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --json state --jq '.state' 2>/dev/null || echo "")
case "$pr_state" in
  MERGED)
    echo "PR #${PR_NUMBER} is already merged; nothing to do"
    exit 0
    ;;
  CLOSED)
    echo "::warning::PR #${PR_NUMBER} is closed without being merged; not merging"
    exit 0
    ;;
esac

# `gh pr merge` judges mergeability client-side and never calls the API, so a
# merge token whose ruleset bypass would allow the merge is refused before it can
# try. The API has no such gate. `sha` is its --match-head-commit.
if [ "${MERGE_WHEN_BLOCKED:-false}" = "true" ]; then
  if api_err=$(try_merge gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/merge" \
    --method PUT -f sha="$PR_HEAD_SHA" -f merge_method="$MERGE_METHOD"); then
    echo "Merged PR #${PR_NUMBER} (${MERGE_METHOD}) through the merge API after the plain merge was refused"
    exit 0
  fi
  echo "::notice::merge API for PR #${PR_NUMBER} was refused too. Reason: $(safe "$api_err")"
fi

echo "::notice::plain merge of PR #${PR_NUMBER} was refused, falling back to auto-merge. Reason: $(safe "$direct_err")"

# This SHA protects the enable-auto-merge mutation, not the eventual queued
# merge. GitHub may keep auto-merge enabled after a later push by an actor with
# write permission; the new head is then governed by repository protections.
# See README "Merging" for the direct-versus-queued guarantee.
if auto_err=$(try_merge gh pr merge "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" \
  --auto --"$MERGE_METHOD" --match-head-commit "$PR_HEAD_SHA"); then
  # Deliberately does NOT promise this lands on its own. Queueing succeeded, but
  # that only means GitHub accepted the request — several refusals reach here
  # with equal confidence and need a human, not patience: a strict
  # "must be up to date with base" rule with no auto-update configured queues
  # indefinitely; a conflict from a base commit landing during the CI wait (up to
  # ~15 min at the default 90x10s) needs the rebase check-pr-ready.sh asks for;
  # and allow_auto_merge being off makes the queue request itself a no-op. Naming
  # the queue and the refusal reason lets the operator tell which, instead of
  # reading a promise and stopping there.
  echo "::warning::PR #${PR_NUMBER} could not be merged immediately and was queued via GitHub auto-merge. It will land only once the remaining requirements are satisfied — if it is still open later, check that (a) auto-merge is enabled on the repository, (b) the branch is up to date with its base, and (c) it has no conflicts. Plain merge was refused with: $(safe "$direct_err" 500)"
  exit 0
fi

api_reason=""
[ -n "${api_err+x}" ] && api_reason=" Merge API said: $(safe "$api_err" 500)."

echo "::error::PR #${PR_NUMBER} was approved but could NOT be merged, and could not be queued for auto-merge either (each path was retried once). Anything waiting on this merge will stall. Plain merge said: $(safe "$direct_err" 500).${api_reason} Auto-merge said: $(safe "$auto_err" 500). Read those reasons first — they name the cause. If they point at policy rather than a transient API error, check branch protection and rulesets (is the token's team a bypass actor during a code freeze?), the token's merge permission, and whether the repository allows auto-merge. No merge-API line above means merge-when-blocked is off, so gh's client-side verdict was final."
exit 1

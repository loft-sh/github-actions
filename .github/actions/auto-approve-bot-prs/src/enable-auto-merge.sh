#!/usr/bin/env bash
# Merges the PR. Never exits non-zero.
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
# Nothing here exits non-zero (the composite must not red-X a caller's CI over
# an unrelated bot PR), but an approved-and-unmerged PR is reported at
# ::error:: level so the cause is visible in the run summary instead of being
# buried in a notice.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, MERGE_METHOD
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${MERGE_METHOD:?MERGE_METHOD required}"

case "$MERGE_METHOD" in
  squash|merge|rebase) ;;
  *)
    echo "::error::Invalid merge method '$MERGE_METHOD'; PR #${PR_NUMBER} was approved but not merged"
    exit 0
    ;;
esac

if direct_err=$(gh pr merge "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --"$MERGE_METHOD" 2>&1); then
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

echo "::notice::plain merge of PR #${PR_NUMBER} was refused, falling back to auto-merge. Reason: ${direct_err}"

if auto_err=$(gh pr merge "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --auto --"$MERGE_METHOD" 2>&1); then
  echo "::warning::PR #${PR_NUMBER} could not be merged immediately; queued via GitHub auto-merge and will land once the remaining requirements pass"
  exit 0
fi

echo "::error::PR #${PR_NUMBER} was approved but could NOT be merged, and could not be queued for auto-merge either. Anything waiting on this merge will stall. Plain merge said: ${direct_err}. Auto-merge said: ${auto_err}. Check branch protection and rulesets (is the token's team a bypass actor during a code freeze?), the token's merge permission, and whether the repository allows auto-merge."

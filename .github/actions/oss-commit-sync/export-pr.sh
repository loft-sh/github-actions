#!/usr/bin/env bash
set -euo pipefail

# Open or update the PR that carries an export run in PR mode into BRANCH.
#
# export.sh has already force-pushed the replay to PR_BRANCH, so an open PR
# is updated by that push alone and only needs finding. With nothing pushed,
# OSS already holds everything, and a PR still open from an earlier run
# would only replay commits OSS has again, so it is closed.
#
# Required env: GH_TOKEN, OSS_REPO, BRANCH, PR_BRANCH, PUSHED.
# Optional env: EXPORTED_COUNT, GITHUB_SERVER_URL, GITHUB_REPOSITORY,
# GITHUB_RUN_ID (link the PR back to the run), GITHUB_OUTPUT.
#
# Outputs: pr-number, pr-url, pr-created.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OSS_REPO="${OSS_REPO:?OSS_REPO is required}"
BRANCH="${BRANCH:?BRANCH is required}"
PR_BRANCH="${PR_BRANCH:?PR_BRANCH is required}"
PUSHED="${PUSHED:-false}"
EXPORTED_COUNT="${EXPORTED_COUNT:-0}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

emit pr-number ""
emit pr-url ""
emit pr-created false

# Captured, not piped: under pipefail a failing gh inside a pipeline is easy to
# lose, and "no open PR" read from a failed lookup opens a duplicate.
open_pr="$(gh pr list --repo "$OSS_REPO" --head "$PR_BRANCH" --base "$BRANCH" --state open \
  --json number,url --jq '.[0] | select(.) | "\(.number) \(.url)"')" \
  || die "failed to look up an open PR from ${PR_BRANCH} into ${BRANCH} on ${OSS_REPO}"

if [ "$PUSHED" != "true" ]; then
  if [ -n "$open_pr" ]; then
    gh pr close "${open_pr%% *}" --repo "$OSS_REPO" --delete-branch \
      --comment "OSS \`${BRANCH}\` already holds everything this PR carried, so it is no longer needed." \
      || die "failed to close stale PR ${open_pr#* }"
    echo "Closed stale PR ${open_pr#* }; OSS ${BRANCH} is up to date"
  fi
  exit 0
fi

if [ -n "$open_pr" ]; then
  number="${open_pr%% *}"
  url="${open_pr#* }"
  echo "Updated PR ${url}"
else
  run_link=""
  if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    run_link=" ([run](${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}))"
  fi
  body="$(cat <<EOF
Replays ${EXPORTED_COUNT} commit(s) from ${GITHUB_REPOSITORY:-the monorepo}${run_link}. Each one keeps its original author and carries a \`${MONOREPO_TRAILER}\` trailer.

Merge with **Rebase and merge** only. A squash makes the PR opener the author of every commit.

Every export run force-pushes this branch, so do not push to it by hand.
EOF
)"
  # The chore() title is what makes the PR eligible for auto-approve-bot-prs.
  url="$(gh pr create --repo "$OSS_REPO" --base "$BRANCH" --head "$PR_BRANCH" \
    --title "chore(sync): export staging to ${BRANCH}" --body "$body")" \
    || die "failed to open a PR from ${PR_BRANCH} into ${BRANCH} on ${OSS_REPO}"
  url="$(printf '%s\n' "$url" | tail -n1)"
  number="${url##*/}"
  emit pr-created true
  echo "Opened PR ${url}"
fi
emit pr-number "$number"
emit pr-url "$url"

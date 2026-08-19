#!/usr/bin/env bash
# Narrow post-CI gate. The full preflight already proved the approver identity
# and waited for mergeability metadata. After CI, only a moved head or a
# definitive conflict should discard the run.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, EXPECTED_HEAD_SHA
# Writes: proceed=true|false to $GITHUB_OUTPUT (and stdout).
# Always exits 0 after validating required env.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${EXPECTED_HEAD_SHA:?EXPECTED_HEAD_SHA required}"

# shellcheck source=.github/actions/auto-approve-bot-prs/src/lib/log.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

if ! pr_state=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
  --jq '[
    (.mergeable | if . == null then "null" else tostring end),
    (.head.sha // "")
  ] | @tsv' 2>/dev/null); then
  echo "::error::could not read PR #${PR_NUMBER} after CI; not approving because the tested head cannot be verified"
  emit proceed false
  exit 0
fi

IFS=$'\t' read -r mergeable current_head <<< "$pr_state"
if [ -z "$current_head" ]; then
  echo "::error::could not resolve the current head SHA for PR #${PR_NUMBER} after CI; not approving because the tested commit cannot be verified"
  emit proceed false
  exit 0
fi
if [ "$current_head" != "$EXPECTED_HEAD_SHA" ]; then
  echo "::error::PR #${PR_NUMBER} head changed from tested SHA '$(safe "$EXPECTED_HEAD_SHA")' to '$(safe "$current_head")'; not approving. The synchronize run for the new head must verify CI instead"
  emit proceed false
  exit 0
fi

if [ "$mergeable" = "false" ]; then
  echo "::warning::PR #${PR_NUMBER} developed merge conflicts while CI was running; not approving. It needs a rebase before this can proceed"
  emit proceed false
  exit 0
fi

if [ "$mergeable" = "null" ]; then
  echo "::notice::GitHub is still computing mergeability for PR #${PR_NUMBER}; continuing because the tested head is unchanged and the merge API will enforce conflicts"
fi
emit proceed true

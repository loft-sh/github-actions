#!/usr/bin/env bash
# Post-CI gate, the last check before approval. The preflight already proved
# the approver identity and rejected a reported conflict. Mergeability is
# decided here, once every other check has finished: a moved head or a
# definitive conflict discards the run, and metadata GitHub still has not
# computed after a bounded wait does not, because the merge API enforces
# conflicts anyway.
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

attempts="${MERGEABLE_MAX_ATTEMPTS:-10}"
sleep_seconds="${MERGEABLE_SLEEP_SECONDS:-3}"
mergeable="null"
read_once=""
for attempt in $(seq 1 "$attempts"); do
  # The preflight read the PR with this token, so a failure here is treated as
  # transient and retried rather than stranding a run whose CI already passed.
  if ! pr_state=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
    --jq '[
      (.mergeable | if . == null then "null" else tostring end),
      (.head.sha // "")
    ] | @tsv' 2>/dev/null); then
    [ "$attempt" -lt "$attempts" ] && sleep "$sleep_seconds"
    continue
  fi

  IFS=$'\t' read -r mergeable current_head <<< "$pr_state"
  read_once=1
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
  [ "$mergeable" != "null" ] && break
  [ "$attempt" -lt "$attempts" ] && sleep "$sleep_seconds"
done

if [ -z "$read_once" ]; then
  echo "::error::could not read PR #${PR_NUMBER} after CI within ${attempts} attempts; not approving because the tested head cannot be verified"
  emit proceed false
  exit 0
fi

if [ "$mergeable" = "false" ]; then
  echo "::warning::PR #${PR_NUMBER} has merge conflicts with its base branch; not approving. It needs a rebase before this can proceed"
  emit proceed false
  exit 0
fi

if [ "$mergeable" = "null" ]; then
  echo "::notice::GitHub did not report mergeability for PR #${PR_NUMBER} within ${attempts} attempts after CI; continuing because the tested head is unchanged and the merge API will enforce conflicts"
fi
emit proceed true

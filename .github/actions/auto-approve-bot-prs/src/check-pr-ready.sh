#!/usr/bin/env bash
# Preflight before the CI wait: the PR is still at the event head, has no
# reported merge conflict, and the approving token is not the PR author.
# Only writes proceed=true if all pass. Mergeability that is not yet computed
# does not block here; check-pr-after-ci.sh decides it once CI has finished.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, PR_AUTHOR,
#               EXPECTED_HEAD_SHA
# Writes: proceed=true|false to $GITHUB_OUTPUT (and stdout).
# Always exits 0.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${PR_AUTHOR:?PR_AUTHOR required}"
: "${EXPECTED_HEAD_SHA:?EXPECTED_HEAD_SHA required}"

# The authenticated login below is API-derived and reaches a log line. The API
# answers in JSON, and a `\r` escape inside a JSON string decodes to a real CR
# through `jq -r`, so "GitHub logins cannot contain control characters" does not
# close that channel. See lib/log.sh.
# shellcheck source=.github/actions/auto-approve-bot-prs/src/lib/log.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/log.sh"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

# This gate runs before the CI wait, so it judges only what is already
# definitive: the head this run was triggered for, a merge conflict GitHub has
# already reported, and the approver identity. Mergeability that GitHub has not
# computed yet is decided after every other check has finished, in
# check-pr-after-ci.sh. Waiting for it here made the action give up before CI
# had even run.
#
# The filter must NOT be `.mergeable // "null"`: jq's `//` treats false as an
# empty value, so a genuine `mergeable: false` (a real merge conflict) came back
# as "null" and was indistinguishable from "GitHub has not computed this yet".
#
# A failed read is not a null mergeable. A token that cannot see the repository
# gets 404 on every poll, and reporting that as "mergeability not computed" sent
# loft-sh/tailscale-acls chasing a GitHub race for an access problem. Access
# errors stop at once with the status; anything else is retried.
read_attempts="${READ_MAX_ATTEMPTS:-10}"
read_sleep="${READ_SLEEP_SECONDS:-3}"
read_error=""
for attempt in $(seq 1 "$read_attempts"); do
  if pr_state=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
    --jq '[
      (.mergeable | if . == null then "null" else tostring end),
      (.head.sha // "")
    ] | @tsv' 2>&1); then
    read_error=""
    break
  fi
  read_error=$(grep -oE 'HTTP [0-9]{3}' <<< "$pr_state" | tail -n1 || true)
  case "$read_error" in
    "HTTP 401"|"HTTP 403"|"HTTP 404")
      echo "::error::the approving token cannot read PR #${PR_NUMBER} (${read_error}); not approving. Give gh-access-token read and write access to pull requests in ${GITHUB_REPOSITORY}"
      emit proceed false
      exit 0
      ;;
  esac
  read_error="${read_error:-an API error}"
  [ "$attempt" -lt "$read_attempts" ] && sleep "$read_sleep"
done
if [ -n "$read_error" ]; then
  echo "::warning::could not read PR #${PR_NUMBER} within ${read_attempts} attempts (last failure: ${read_error}); not approving. This is usually transient - a re-run should resolve it"
  emit proceed false
  exit 0
fi
IFS=$'\t' read -r mergeable current_head <<< "$pr_state"

# A synchronize event can move the PR while this workflow is queued. Check the
# event SHA first so a force-push reports the real reason.
if [ -z "$current_head" ]; then
  echo "::error::could not resolve the current head SHA for PR #${PR_NUMBER}; not approving because the tested commit cannot be verified"
  emit proceed false
  exit 0
fi
if [ "$current_head" != "$EXPECTED_HEAD_SHA" ]; then
  echo "::error::PR #${PR_NUMBER} head changed from tested SHA '$(safe "$EXPECTED_HEAD_SHA")' to '$(safe "$current_head")'; not approving. The synchronize run for the new head must verify CI instead"
  emit proceed false
  exit 0
fi

# A reported conflict is definitive, and waiting out the whole CI budget on it
# would only delay the rebase it needs.
if [ "$mergeable" = "false" ]; then
  echo "::warning::PR #${PR_NUMBER} has merge conflicts with its base branch; not approving. It needs a rebase before this can proceed"
  emit proceed false
  exit 0
fi

# GitHub forbids self-approval. Pre-empt hmarr's 422 setFailed path.
#
# Split from the identity check below because an unusable token and a
# same-identity token are different problems: the first means GH_TOKEN is
# expired or lacks scope, the second means the caller passed the PR author's own
# credentials. Both are misconfigurations that can never succeed on a retry,
# hence ::error:: rather than a notice.
approver=$(gh api user --jq '.login' 2>/dev/null || echo "")
if [ -z "$approver" ]; then
  echo "::error::could not resolve the authenticated user from the supplied token; not approving PR #${PR_NUMBER}. The token is likely expired or missing the scope needed to read the current user"
  emit proceed false
  exit 0
fi
if [ "$approver" = "$PR_AUTHOR" ]; then
  echo "::error::the approving identity ('$(safe "$approver")') is the author of PR #${PR_NUMBER}; GitHub forbids self-approval. Pass a token belonging to a different identity than the PR author"
  emit proceed false
  exit 0
fi

emit proceed true

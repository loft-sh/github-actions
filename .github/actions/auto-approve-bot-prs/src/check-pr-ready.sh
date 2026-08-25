#!/usr/bin/env bash
# Combines two gates: merge-conflict check and approver-identity check.
# Only writes proceed=true if BOTH pass.
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

# mergeable can be null briefly while GitHub computes metadata. Rerun context
# makes this worse — observed runs where the first ~9s window returned null
# even though the PR had been mergeable for hours. Budget ~30s before giving up.
#
# The filter must NOT be `.mergeable // "null"`: jq's `//` treats false as an
# empty value, so a genuine `mergeable: false` (a real merge conflict) came back
# as "null" and was indistinguishable from "GitHub has not computed this yet" —
# which also meant a conflicted PR burned the whole retry budget re-polling a
# value that was already definitive.
mergeable="null"
mergeable_attempts="${MERGEABLE_MAX_ATTEMPTS:-10}"
mergeable_sleep="${MERGEABLE_SLEEP_SECONDS:-3}"
for _ in $(seq 1 "$mergeable_attempts"); do
  if ! pr_state=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
    --jq '[
      (.mergeable | if . == null then "null" else tostring end),
      (.head.sha // "")
    ] | @tsv' 2>/dev/null); then
    mergeable="null"
    sleep "$mergeable_sleep"
    continue
  fi
  IFS=$'\t' read -r mergeable current_head <<< "$pr_state"

  # A synchronize event can move the PR while this workflow is polling. Check
  # the event SHA before waiting for GitHub to recompute mergeability so a
  # force-push reports the real reason immediately instead of timing out.
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

  [ "$mergeable" != "null" ] && break
  sleep "$mergeable_sleep"
done

# Both outcomes below stop the run, but they need different responses, so they
# are reported separately rather than as one notice: a conflict needs someone to
# rebase the PR, whereas exhausting the metadata budget is transient and a re-run
# is likely to succeed.
if [ "$mergeable" = "false" ]; then
  echo "::warning::PR #${PR_NUMBER} has merge conflicts with its base branch; not approving. It needs a rebase before this can proceed"
  emit proceed false
  exit 0
fi
if [ "$mergeable" != "true" ]; then
  echo "::warning::GitHub did not report mergeability for PR #${PR_NUMBER} within ${mergeable_attempts} attempts (last value '$(safe "$mergeable")'); not approving. This is usually transient - a re-run should resolve it"
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

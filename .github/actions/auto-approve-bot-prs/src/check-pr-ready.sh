#!/usr/bin/env bash
# Combines two gates: merge-conflict check and approver-identity check.
# Only writes proceed=true if BOTH pass.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, PR_AUTHOR
# Writes: proceed=true|false to $GITHUB_OUTPUT (and stdout).
# Always exits 0.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_NUMBER:?PR_NUMBER required}"
: "${PR_AUTHOR:?PR_AUTHOR required}"

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
  mergeable=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
    --jq '.mergeable | if . == null then "null" else tostring end' 2>/dev/null || echo "null")
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
  echo "::warning::GitHub did not report mergeability for PR #${PR_NUMBER} within ${mergeable_attempts} attempts (last value '${mergeable}'); not approving. This is usually transient - a re-run should resolve it"
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
  echo "::error::the approving identity ('${approver}') is the author of PR #${PR_NUMBER}; GitHub forbids self-approval. Pass a token belonging to a different identity than the PR author"
  emit proceed false
  exit 0
fi

emit proceed true

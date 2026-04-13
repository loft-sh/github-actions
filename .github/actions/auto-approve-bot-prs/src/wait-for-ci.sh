#!/usr/bin/env bash
# Polls non-self check-runs on the PR head until they complete.
# Outputs ci_green=true only if every non-self check ends success/skipped/neutral.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_HEAD_SHA, SELF_RUN_ID
# Optional env: WAIT_MAX_ATTEMPTS (default 90), WAIT_SLEEP_SECONDS (default 10)
# Writes: ci_green=true|false to $GITHUB_OUTPUT (and stdout).
# Always exits 0.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_HEAD_SHA:?PR_HEAD_SHA required}"
: "${SELF_RUN_ID:?SELF_RUN_ID required}"

max_attempts="${WAIT_MAX_ATTEMPTS:-90}"
sleep_seconds="${WAIT_SLEEP_SECONDS:-10}"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

# Self-identification: exclude check-runs whose details_url contains our run id,
# `.../runs/<SELF_RUN_ID>/...`. Works for both check-runs and statuses from
# github-actions.
EXCLUDE_PATTERN="/runs/${SELF_RUN_ID}/"

for attempt in $(seq 1 "$max_attempts"); do
  runs=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/check-runs" --paginate --jq '.check_runs // []' 2>/dev/null || echo '[]')
  other=$(echo "$runs" | jq --arg p "$EXCLUDE_PATTERN" '[.[] | select((.details_url // "") | contains($p) | not)]')
  pending=$(echo "$other" | jq '[.[] | select(.status != "completed")] | length')
  failed=$(echo  "$other" | jq '[.[] | select(.conclusion != null and ([.conclusion] | inside(["success","skipped","neutral"]) | not))] | length')
  echo "attempt ${attempt}/${max_attempts}: pending=${pending} failed=${failed}"

  if [ "${failed:-0}" -gt 0 ]; then
    echo "::notice::Other CI checks failed; skipping approval"
    emit ci_green false
    exit 0
  fi
  if [ "${pending:-0}" -eq 0 ]; then
    emit ci_green true
    exit 0
  fi
  sleep "$sleep_seconds"
done

echo "::notice::Timed out waiting for other CI checks"
emit ci_green false

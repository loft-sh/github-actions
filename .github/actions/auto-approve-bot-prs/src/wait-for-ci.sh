#!/usr/bin/env bash
# Polls non-self check-runs AND commit statuses on the PR head until they
# complete. Outputs ci_green=true only if every non-self signal ends
# success/skipped/neutral.
#
# Commit statuses matter because external systems (Netlify, etc.) post results
# via the legacy statuses API, not check-runs. Without this, the script sees
# "nothing pending" and approves while Netlify is still reporting failures.
#
# A minimum number of attempts is also required before declaring green: an
# external check that has not yet registered a "pending" signal looks
# indistinguishable from "no check configured". Waiting one settle period
# lets slow registrants (observed: Netlify, ~2 min) appear before approval.
#
# Required env: GH_TOKEN, GITHUB_REPOSITORY, PR_HEAD_SHA, SELF_RUN_ID
# Optional env:
#   WAIT_MAX_ATTEMPTS  (default 90)  – hard ceiling on polls
#   WAIT_MIN_ATTEMPTS  (default 12)  – floor before ci_green=true is allowed
#   WAIT_SLEEP_SECONDS (default 10)  – seconds between polls
# Writes: ci_green=true|false to $GITHUB_OUTPUT (and stdout).
# Always exits 0.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
: "${PR_HEAD_SHA:?PR_HEAD_SHA required}"
: "${SELF_RUN_ID:?SELF_RUN_ID required}"

max_attempts="${WAIT_MAX_ATTEMPTS:-90}"
min_attempts="${WAIT_MIN_ATTEMPTS:-12}"
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
  # Dedupe by name: GitHub keeps historical attempts (including cancelled ones
  # superseded by reruns) in the check-runs list, and the current state is the
  # one with the latest started_at. Treating every past attempt as live is what
  # makes a superseded `cancelled` from an older run silently block approval
  # even though the same check's latest attempt is green.
  #
  # `.id` is the tiebreaker when two attempts share an identical started_at —
  # a common case when concurrency-group cancellation and the winning run
  # start within the same second. GitHub allocates check-run IDs
  # monotonically, so the larger id is always the newer attempt.
  other=$(echo "$runs" | jq --arg p "$EXCLUDE_PATTERN" '
    [.[] | select((.details_url // "") | contains($p) | not)]
    | group_by(.name // "")
    | map(sort_by(.started_at // "", .id // 0) | last)
  ')
  cr_pending=$(echo "$other" | jq '[.[] | select(.status != "completed")] | length')
  cr_failed=$( echo "$other" | jq '[.[] | select(.conclusion != null and ([.conclusion] | inside(["success","skipped","neutral"]) | not))] | length')
  cr_failed_names=$(echo "$other" | jq -r '[.[] | select(.conclusion != null and ([.conclusion] | inside(["success","skipped","neutral"]) | not)) | .name // "unnamed"] | join(", ")')

  # Commit statuses API (/commits/SHA/status) returns the combined state plus
  # one entry per context (already the latest per context). Netlify, Travis,
  # CircleCI and similar legacy CIs report here — not via check-runs.
  statuses=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/status" --jq '.statuses // []' 2>/dev/null || echo '[]')
  # Drop our own statuses (self-identification via target_url pointing at our
  # run id) — harmless if github-actions never posts via the statuses API,
  # but future-proofs against callers that do.
  statuses_other=$(echo "$statuses" | jq --arg p "$EXCLUDE_PATTERN" '[.[] | select((.target_url // "") | contains($p) | not)]')
  st_pending=$(echo "$statuses_other" | jq '[.[] | select(.state == "pending")] | length')
  st_failed=$( echo "$statuses_other" | jq '[.[] | select(.state == "failure" or .state == "error")] | length')
  st_failed_names=$(echo "$statuses_other" | jq -r '[.[] | select(.state == "failure" or .state == "error") | .context // "unnamed"] | join(", ")')

  pending=$(( cr_pending + st_pending ))
  failed=$(( cr_failed + st_failed ))
  echo "attempt ${attempt}/${max_attempts}: check_runs(pending=${cr_pending} failed=${cr_failed}) statuses(pending=${st_pending} failed=${st_failed})"

  if [ "$failed" -gt 0 ]; then
    failed_all=$(printf '%s\n%s' "$cr_failed_names" "$st_failed_names" | awk 'NF' | paste -sd, - | sed 's/,/, /g')
    echo "::notice::Other CI checks failed; skipping approval. Failing: ${failed_all:-unknown}"
    emit ci_green false
    exit 0
  fi
  # Hold the "green" verdict until the settle floor. A first-poll "pending=0"
  # can simply mean external checks have not registered yet (e.g. Netlify
  # webhook still in flight). Waiting min_attempts polls before the first
  # green verdict gives slow registrants a chance to show up.
  if [ "$pending" -eq 0 ] && [ "$attempt" -ge "$min_attempts" ]; then
    emit ci_green true
    exit 0
  fi
  sleep "$sleep_seconds"
done

echo "::notice::Timed out waiting for other CI checks"
emit ci_green false

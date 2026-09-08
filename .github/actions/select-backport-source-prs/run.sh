#!/usr/bin/env bash
set -euo pipefail

repository="${INPUT_REPOSITORY:?INPUT_REPOSITORY is required}"
source_pr="${INPUT_SOURCE_PR:-}"
lookback_days="${INPUT_LOOKBACK_DAYS:-30}"
label_prefix="${INPUT_LABEL_PREFIX:-backport-to-}"
output_file="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ ! "$repository" =~ ^[^/]+/[^/]+$ ]]; then
  echo "::error::repository must use owner/repo form, got '$repository'"
  exit 1
fi

if [[ -n "$source_pr" ]]; then
  if [[ ! "$source_pr" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::source-pr must be a positive integer, got '$source_pr'"
    exit 1
  fi
  source_prs="[$source_pr]"
  selection="explicit source PR"
else
  if [[ ! "$lookback_days" =~ ^[1-9][0-9]*$ ]] || (( lookback_days > 365 )); then
    echo "::error::lookback-days must be an integer from 1 to 365, got '$lookback_days'"
    exit 1
  fi
  cutoff="$(date -u -d "$lookback_days days ago" +%F)"
  results="$(gh pr list --repo "$repository" --state merged --search "merged:>=$cutoff" --limit 1000 --json number,labels,state)"
  if (( $(jq 'length' <<<"$results") == 1000 )); then
    echo "::error::merged PR search reached GitHub's 1000-result limit; reduce lookback-days"
    exit 1
  fi
  source_prs="$(jq -c --arg prefix "$label_prefix" '
    [.[]
      | select(.state == "MERGED")
      | select(any(.labels[]?; .name | startswith($prefix)))
      | .number]
    | unique
    | sort
  ' <<<"$results")"
  selection="$lookback_days-day lookback from $cutoff"
fi

selected_count="$(jq 'length' <<<"$source_prs")"
{
  echo "source-prs=$source_prs"
  echo "selected-count=$selected_count"
} >> "$output_file"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Backport link sweep selection"
    echo
    echo "Repository: \`$repository\`"
    echo "Selection: $selection"
    echo
    if (( selected_count == 0 )); then
      echo "No merged source PRs with \`$label_prefix*\` labels were selected."
    else
      jq -r --arg repository "$repository" '.[] | "- `\($repository)#\(.)`"' <<<"$source_prs"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

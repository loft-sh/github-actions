#!/usr/bin/env bash
set -euo pipefail

# Advance existing action major tags to a merged PR commit. This script is
# invoked by the post-merge workflow with a full checkout and GH_TOKEN.

fail() {
  echo "::error::$*" >&2
  exit 1
}

command -v gh >/dev/null || fail "gh CLI is required to read merged PR files"
command -v jq >/dev/null || fail "jq is required to read the pull request event"

: "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

git_authenticated() {
  local token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  if [[ -n "$token" ]]; then
    local auth
    auth=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" \
      git "$@"
  else
    git "$@"
  fi
}

# A pull_request event carries the PR; a push to main is resolved to the PR
# whose merge commit it is, so both read the same fields below.
if jq -e '.pull_request | type == "object"' "$GITHUB_EVENT_PATH" >/dev/null; then
  pr_json=$(jq -c '.pull_request' "$GITHUB_EVENT_PATH")
else
  push_sha=$(jq -er '.after | select(type == "string" and length > 0)' "$GITHUB_EVENT_PATH") || fail "Push event has no commit SHA"
  pr_json=""

  # Squash and merge commits name their PR; trust it only if GitHub records
  # this push as that PR's merge commit.
  subject=$(jq -r '.head_commit.message // "" | split("\n")[0]' "$GITHUB_EVENT_PATH")
  named_pr=""
  if [[ "$subject" =~ \(#([0-9]+)\)$ || "$subject" =~ ^Merge\ pull\ request\ \#([0-9]+) ]]; then
    named_pr=${BASH_REMATCH[1]}
  fi
  if [[ -n "$named_pr" ]]; then
    candidate=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$named_pr") || fail "Could not read PR #$named_pr named by $push_sha"
    if jq -e --arg sha "$push_sha" '.merge_commit_sha == $sha' >/dev/null <<< "$candidate"; then
      pr_json=$candidate
    fi
  fi

  # Rebase merges name no PR. GitHub links a fresh merge commit to its PR
  # late, and sometimes never, so this is the fallback, not the first source.
  if [[ -z "$pr_json" ]]; then
    pr_number=""
    for attempt in 1 2 3; do
      pulls_json=$(gh api "repos/$GITHUB_REPOSITORY/commits/$push_sha/pulls") || fail "Could not list pull requests for $push_sha"
      pr_number=$(jq -r --arg sha "$push_sha" '[.[]? | select(.merge_commit_sha == $sha) | .number][0] // empty' <<< "$pulls_json") || fail "Could not parse pull requests for $push_sha"
      [[ -z "$pr_number" && "$attempt" -lt 3 ]] || break
      sleep "${ADVANCE_TAGS_LOOKUP_DELAY:-10}"
    done
    # main requires pull requests, so a push with no PR is unexpected.
    [[ -n "$pr_number" ]] || fail "No merged pull request found for $push_sha; tags were not changed. Advance them manually if this push changed an action."
    # Export now so a failed read below still gets its failure comment.
    [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "pr-number=$pr_number" >> "$GITHUB_OUTPUT"
    pr_number_exported=1
    pr_json=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$pr_number") || fail "Could not read PR #$pr_number"
  fi
fi

pr_number=$(jq -er '.number' <<< "$pr_json") || fail "Event has no pull request number"
[[ -n "${pr_number_exported:-}" || -z "${GITHUB_OUTPUT:-}" ]] || echo "pr-number=$pr_number" >> "$GITHUB_OUTPUT"
merged=$(jq -r '.merged // false' <<< "$pr_json")
[[ "$merged" == true ]] || fail "Pull request #$pr_number is not merged"
merge_sha=$(jq -er '.merge_commit_sha | select(type == "string" and length > 0)' <<< "$pr_json") || fail "Merged pull request has no merge commit SHA"

files_json=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/pulls/$pr_number/files") || fail "Could not list files changed by PR #$pr_number"
if ! jq -e 'type == "array" and all(.[]; type == "array" and all(.[]; type == "object" and (.filename | type == "string" and length > 0)))' >/dev/null <<< "$files_json"; then
  fail "GitHub returned malformed changed-file data for PR #$pr_number"
fi
file_count=$(jq '[.[][]] | length' <<< "$files_json") || fail "Could not parse the changed file list for PR #$pr_number"
(( file_count < 3000 )) || fail "PR #$pr_number changed at least 3000 files; GitHub may have truncated the list, so tags were not changed"
event_file_count=$(jq -r '.changed_files // empty' <<< "$pr_json")
if [[ -n "$event_file_count" && "$event_file_count" != "$file_count" ]]; then
  fail "GitHub returned $file_count changed files for PR #$pr_number, but the event reports $event_file_count; tags were not changed"
fi

declare -A changed_actions=()
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if [[ "$path" =~ ^\.github/actions/([^/]+)/ ]]; then
    changed_actions["${BASH_REMATCH[1]}"]=1
  fi
done < <(jq -r '.[][] | [.filename, .previous_filename] | .[]? | select(type == "string")' <<< "$files_json")

if [[ ${#changed_actions[@]} -eq 0 ]]; then
  echo "No action directories changed in PR #$pr_number; no tags to advance."
  exit 0
fi

major_release=$(jq -r '[.labels[]?.name] | any(. == "major-release")' <<< "$pr_json")
if [[ "$major_release" == true ]]; then
  fail "PR #$pr_number declares major-release; create a new major tag and leave existing tags unchanged"
fi

git_authenticated fetch --quiet --force --prune origin main '+refs/tags/*:refs/tags/*' || fail "Could not fetch origin/main and action tags"
git cat-file -e "$merge_sha^{commit}" 2>/dev/null || fail "Merge commit $merge_sha is unavailable in this checkout"
git merge-base --is-ancestor "$merge_sha" origin/main || fail "Merge commit $merge_sha is not an ancestor of origin/main"

declare -a tags_to_move=()
declare -A old_shas=()
declare -A old_ref_oids=()
for action in "${!changed_actions[@]}"; do
  # Actions that download versioned binaries need their release workflow too;
  # moving their coordination tag alone would point callers at stale artifacts.
  [[ "$action" != linear-release-sync ]] || fail "linear-release-sync is a binary action; its tag cannot be moved without rebuilding its release artifact"

  if ! git cat-file -e "$merge_sha:.github/actions/$action/action.yml" 2>/dev/null; then
    fail "Changed action $action is missing action.yml at merge commit $merge_sha; tag target is unclear"
  fi

  best_version=0
  best_tag=""
  while IFS= read -r tag; do
    [[ "$tag" == "$action/v"* ]] || continue
    version=${tag#"$action/v"}
    [[ "$version" =~ ^[1-9][0-9]*$ ]] || continue
    if (( version > best_version )); then
      best_version=$version
      best_tag=$tag
    fi
  done < <(git tag --list "$action/v*")

  if [[ -z "$best_tag" ]]; then
    echo "No existing major tag for $action; skipping."
    continue
  fi

  old_sha=$(git rev-parse "$best_tag^{commit}") || fail "Could not resolve existing tag $best_tag"
  old_ref_oid=$(git rev-parse "refs/tags/$best_tag") || fail "Could not resolve tag ref $best_tag"
  git merge-base --is-ancestor "$old_sha" "$merge_sha" || fail "Tag $best_tag ($old_sha) is not an ancestor of merge commit $merge_sha; refusing a backwards or unrelated move"
  if [[ "$old_sha" != "$merge_sha" ]]; then
    tags_to_move+=("$best_tag")
    old_shas["$best_tag"]=$old_sha
    old_ref_oids["$best_tag"]=$old_ref_oid
  fi
done

# All tags are checked before the first write. One atomic push with explicit
# leases makes a concurrent update fail without partially moving other tags.
if [[ ${#tags_to_move[@]} -gt 0 ]]; then
  push_args=(--quiet --atomic)
  refspecs=()
  for tag in "${tags_to_move[@]}"; do
    push_args+=("--force-with-lease=refs/tags/$tag:${old_ref_oids[$tag]}")
    refspecs+=("$merge_sha:refs/tags/$tag")
  done

  git_authenticated push "${push_args[@]}" origin "${refspecs[@]}" \
    || fail "Could not advance action tags; a remote tag changed or the atomic push was rejected"
fi

for tag in "${tags_to_move[@]}"; do
  echo "Advanced $tag from ${old_shas[$tag]} to $merge_sha."
done

if [[ ${#tags_to_move[@]} -eq 0 ]]; then
  echo "No existing action tags need advancing for PR #$pr_number."
fi

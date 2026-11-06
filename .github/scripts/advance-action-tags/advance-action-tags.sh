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

pr_number=$(jq -er '.pull_request.number' "$GITHUB_EVENT_PATH") || fail "Event has no pull request number"
merged=$(jq -r '.pull_request.merged // false' "$GITHUB_EVENT_PATH")
[[ "$merged" == true ]] || fail "Pull request #$pr_number is not merged"
merge_sha=$(jq -er '.pull_request.merge_commit_sha | select(type == "string" and length > 0)' "$GITHUB_EVENT_PATH") || fail "Merged pull request has no merge commit SHA"

files_json=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/pulls/$pr_number/files") || fail "Could not list files changed by PR #$pr_number"
if ! jq -e 'type == "array" and all(.[]; type == "array" and all(.[]; type == "object" and (.filename | type == "string" and length > 0)))' >/dev/null <<< "$files_json"; then
  fail "GitHub returned malformed changed-file data for PR #$pr_number"
fi
file_count=$(jq '[.[][]] | length' <<< "$files_json") || fail "Could not parse the changed file list for PR #$pr_number"
(( file_count < 3000 )) || fail "PR #$pr_number changed at least 3000 files; GitHub may have truncated the list, so tags were not changed"
event_file_count=$(jq -r '.pull_request.changed_files // empty' "$GITHUB_EVENT_PATH")
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

major_release=$(jq -r '[.pull_request.labels[]?.name] | any(. == "major-release")' "$GITHUB_EVENT_PATH")
if [[ "$major_release" == true ]]; then
  fail "PR #$pr_number declares major-release; create a new major tag and leave existing tags unchanged"
fi

git_authenticated fetch --quiet --force --prune origin main '+refs/tags/*:refs/tags/*' || fail "Could not fetch origin/main and action tags"
git cat-file -e "$merge_sha^{commit}" 2>/dev/null || fail "Merge commit $merge_sha is unavailable in this checkout"
git merge-base --is-ancestor "$merge_sha" origin/main || fail "Merge commit $merge_sha is not an ancestor of origin/main"

# Actions also load files from other directories by relative path:
# release-summary imports ../release-lib, and semver-validation runs
# ../setup-semstat/src/install-semstat.sh. A fix in such a directory only
# reaches callers through the tags of the actions that load it, so those
# advance too, followed through every directory that is loaded in turn. A
# file outside markdown and test/ loads a directory when it names it after a
# slash with no name character after it, as in ../<dir> or {root}/<dir>/, or
# as a whole quoted string, "<dir>" or '<dir>'. <dir>@<ref> is a remote uses:
# that loads the action at its own tag, so it does not count.
# A changed directory without action.yml is a library such as release-lib,
# which advances no tag of its own, as long as it exists at the merge commit
# and never had an action.yml. Any other directory without action.yml is a
# removed or renamed action, which has no clear tag target. History, not the
# merge commit's parent, decides "never": a rebase merge lands each commit of
# the pull request, so the parent can already lack the action.yml.
users_of() {
  local dir=$1 matches status=0 name
  # Directory names hold only [A-Za-z0-9._-], so a dot is the one character
  # to escape for the regex.
  name=${dir//./\\.}
  matches=$(git grep -l -E -e "/$name([^A-Za-z0-9_.@-]|\$)" -e "[\"']${name}[\"']" \
    "$merge_sha" -- .github/actions ":(exclude).github/actions/$dir" ':(exclude)*.md' \
    ':(exclude,glob).github/actions/*/test/**') || status=$?
  # git grep exits 1 for no match and above 1 when it cannot search.
  (( status <= 1 )) || fail "Could not search merge commit $merge_sha for users of $dir"
  sed -nE "s#^$merge_sha:\.github/actions/([^/]+)/.*#\1#p" <<< "$matches" | sort -u
}

declare -a queue=("${!changed_actions[@]}")
declare -A visited=()
while [[ ${#queue[@]} -gt 0 ]]; do
  dir=${queue[0]}
  queue=("${queue[@]:1}")
  [[ -z "${visited[$dir]:-}" ]] || continue
  visited[$dir]=1
  [[ "$dir" != linear-release-sync ]] || fail "linear-release-sync is a binary action; its tag cannot be moved without rebuilding its release artifact"

  library=false
  if ! git cat-file -e "$merge_sha:.github/actions/$dir/action.yml" 2>/dev/null; then
    if git cat-file -e "$merge_sha:.github/actions/$dir" 2>/dev/null \
        && [[ -z "$(git log -1 --format=%H "$merge_sha" -- ".github/actions/$dir/action.yml")" ]]; then
      library=true
      unset 'changed_actions[$dir]'
    else
      fail "Changed action $dir is missing action.yml at merge commit $merge_sha; tag target is unclear"
    fi
  fi

  users=$(users_of "$dir")
  if [[ -z "$users" ]]; then
    [[ "$library" == false ]] || fail "Changed directory $dir has no action.yml and no action uses it at merge commit $merge_sha; tag target is unclear"
    continue
  fi
  echo "$dir is loaded by: $(tr '\n' ' ' <<< "$users")"
  while IFS= read -r user; do
    if git cat-file -e "$merge_sha:.github/actions/$user/action.yml" 2>/dev/null; then
      changed_actions["$user"]=1
    fi
    queue+=("$user")
  done <<< "$users"
done

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

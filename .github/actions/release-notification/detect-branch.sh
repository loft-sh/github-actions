#!/usr/bin/env bash
# detect-branch.sh: name the branch a release tag was cut from.
#
# Resolution order, first match wins:
#   1. BASE_BRANCH, the caller's answer, when the tag commit is on it. It is
#      also trusted when it cannot be checked (no checkout, tag not fetched,
#      branch deleted after the cut), since the caller picked it. A branch the
#      tag is no longer on is kept only when it is a rebasable source for the
#      version: a feature branch for a -next, the version's line for an rc or
#      a stable. HEAD and the other pseudo-refs, origin, the release tag and
#      ref-shaped names (refs/, heads/, tags/, remotes/, origin/) are ignored,
#      and so are other tags and SHAs when a checkout can tell. With no
#      checkout, any hex name of 7 to 64 characters counts as a SHA. A branch
#      git cannot check because history is missing is trusted, with a warning.
#   2. The default branch and the version's release line (release-X.Y or
#      vX.Y), when they contain the tag commit. Stables check the line first,
#      since they are only cut there. An rc at the commit the line forked from
#      the default branch is reported as the line: rcs at a fork point have
#      been cut from either, slightly more often from the line, and git cannot
#      tell them apart. Other prereleases check the default branch first.
#      -next tags skip this step, since they come from feature branches.
#   3. The remote branch containing the tag commit whose tip is closest. This
#      is a guess, reached when neither the default branch nor the line holds
#      the tag, or for a -next tag, which prefers feature branches. When no
#      branch passes, a -next falls back to the default branch if it holds the
#      tag.
#
# Required environment variables:
#   RELEASE_VERSION  the release tag (e.g. v1.2.3)
#
# Optional environment variables:
#   BASE_BRANCH      the branch the caller says the tag was cut from
#   DEFAULT_BRANCH   fallback branch name (default: main)
#
# Output (stdout): the detected branch name. A tag that cannot be read is a
# warning, not a failure, so a missing checkout never blocks the banner. The
# checkout needs full history and tags for anything past step 1.

set -euo pipefail

# shellcheck source=.github/actions/release-lib/lib.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../release-lib/lib.sh"

: "${RELEASE_VERSION:?RELEASE_VERSION must be set}"
RELEASE_VERSION="$(trim "$(flatten "$RELEASE_VERSION")")"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
BASE_BRANCH="$(trim "${BASE_BRANCH:-}")"
# Both namings in use: loft-enterprise cuts release-X.Y, vcluster-pro vX.Y.
# shellcheck disable=SC2034 # read by release-lib's is_feature_branch
LINE_BRANCH_PATTERN='^(release-|v)[0-9]+\.[0-9]+$'

# The name is quoted into the Slack payload's YAML and into log annotations,
# so it has to pass the same rule platform-release applies to it. origin is a
# branch name to GitHub, but in this checkout it is the remote and resolves to
# origin/HEAD.
valid_branch() {
  validate_branch "$1" 2>/dev/null && [[ "$1" != origin ]]
}

# Spelled out in full: a tag or local branch named origin/X would shadow it.
remote() {
  printf 'refs/remotes/origin/%s' "$1"
}

# 0 when the walk from the branch toward the tag crosses a shallow boundary, so
# a "no" from git may only mean the history ran out. Every commit on a path
# from the branch to the tag is in `branch ^tag`, so with no boundary commit
# there, git's "no" is final.
shallow_cut() {
  local file revs
  file="$(git rev-parse --git-path shallow)"
  [[ -s "$file" ]] || return 1
  revs="$(git rev-list "$(remote "$1")" "^$TAG_COMMIT")" || return 0
  grep -qxFf "$file" <<<"$revs"
}

# 0 when the tag commit is on the remote branch, 1 when it is not, 2 when git
# cannot tell: an object is missing (git errors), or a shallow checkout's
# history is cut between the branch and the tag (git answers "no"). Reading
# that as "not on it" would drop a right answer. 3 when the remote has no such
# branch.
on_branch() {
  # shellcheck disable=SC2034 # is-ancestor prints nothing
  local out err rc=0 reason
  git rev-parse --verify -q "$(remote "$1")" >/dev/null || return 3
  run_captured out err git merge-base --is-ancestor "$TAG_COMMIT" "$(remote "$1")" || rc=$?
  ((rc == 0)) && return 0
  if ((rc == 1)); then
    shallow_cut "$1" || return 1
    reason="The checkout is shallow, and its history from $1 is cut before git could rule the tag out."
  else
    reason="git said: $(flatten "$err")"
  fi
  echo "::warning::cannot check whether $RELEASE_VERSION is on $1. $reason" >&2
  return 2
}

# A hex name is a commit only when the checkout holds one by that prefix, so a
# branch named 20251005 is kept. With no checkout to ask, the shape decides.
names_commit() {
  local types
  [[ "$1" =~ ^[0-9a-f]{7,64}$ ]] || return 1
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  types="$(git rev-parse --disambiguate="$1" 2>/dev/null |
           git cat-file --batch-check='%(objecttype)' 2>/dev/null)" || true
  [[ $'\n'"$types"$'\n' == *$'\n'commit$'\n'* ]]
}

# Prints why a name git resolves to something other than a branch is not one.
# Only asked once the name is not on the remote, where a real branch would be.
not_a_branch() {
  if [[ "$1" =~ ^(origin|heads|tags|remotes)/ ]]; then
    echo "is a ref path"
  elif git show-ref --verify -q "refs/tags/$1" 2>/dev/null; then
    echo "names a tag"
  elif names_commit "$1"; then
    echo "names a commit"
  else
    return 1
  fi
}

drop_base() {
  echo "::warning::base_branch $BASE_BRANCH $1, not a branch, detecting the branch from git history instead" >&2
  BASE_BRANCH=""
}

emit() {
  echo "Detected source branch: $1 ($2)" >&2
  echo "$1"
  exit 0
}

if [[ -n "$BASE_BRANCH" ]] && ! valid_branch "$BASE_BRANCH"; then
  echo "::warning::base_branch is not a plain branch name, ignoring it and detecting the branch from git history" >&2
  BASE_BRANCH=""
fi
if [[ -n "$BASE_BRANCH" && "$BASE_BRANCH" == "$RELEASE_VERSION" ]]; then
  drop_base "is the release tag"
fi
SUFFIX="$(classify_suffix "$RELEASE_VERSION" 2>/dev/null)" || SUFFIX=other
LINE_BRANCHES=()
# derive_line reads v1 as 1.1, so only a full X.Y.Z gets a line.
if [[ "$RELEASE_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9] ]]; then
  for FORMAT in 'release-%s.%s' 'v%s.%s'; do
    LINE="$(LINE_BRANCH_FORMAT="$FORMAT" derive_line "$RELEASE_VERSION" 2>/dev/null)" && LINE_BRANCHES+=("$LINE")
  done
fi

# Lines and feature branches get rewritten after a cut; main does not.
rebasable_source() {
  case "$SUFFIX" in
    next|next-internal) is_feature_branch "$1" ;;
    rc|stable) [[ " ${LINE_BRANCHES[*]-} " == *" $1 "* ]] ;;
    *) return 1 ;;
  esac
}

# Only an existing tag ref, so a version shaped like an option, a revision
# (v1^, main..), git describe output or a branch name reads as no tag.
read_tag() {
  # shellcheck disable=SC2034 # show-ref is asked for its exit code only
  local ref
  run_captured ref TAG_ERR git show-ref --verify "refs/tags/$RELEASE_VERSION" &&
    run_captured TAG_COMMIT TAG_ERR git rev-parse --verify "refs/tags/$RELEASE_VERSION^{commit}" &&
    return 0
  TAG_ERR="git said: $(flatten "$TAG_ERR")"
  return 1
}

if ! read_tag; then
  if [[ -n "$BASE_BRANCH" ]] && REASON="$(not_a_branch "$BASE_BRANCH")"; then
    drop_base "$REASON"
  fi
  [[ -n "$BASE_BRANCH" ]] && emit "$BASE_BRANCH" "given, tag not available to check"
  echo "::warning::cannot read tag $RELEASE_VERSION, so the source branch is shown as '$DEFAULT_BRANCH'. $TAG_ERR" >&2
  emit "$DEFAULT_BRANCH" "fallback, tag not readable"
fi

if [[ -n "$BASE_BRANCH" ]]; then
  RC=0
  on_branch "$BASE_BRANCH" || RC=$?
  case "$RC" in
    0) emit "$BASE_BRANCH" "given" ;;
    2) emit "$BASE_BRANCH" "given, git could not check it" ;;
    1)
      rebasable_source "$BASE_BRANCH" && emit "$BASE_BRANCH" "given, rebased since the cut"
      echo "::warning::$RELEASE_VERSION is not on $BASE_BRANCH, detecting the branch from git history instead" >&2
      BASE_BRANCH="" ;;
    *)
      if REASON="$(not_a_branch "$BASE_BRANCH")"; then
        drop_base "$REASON"
      else
        emit "$BASE_BRANCH" "given, branch not on remote to check"
      fi ;;
  esac
fi

if [[ "$SUFFIX" == rc ]]; then
  for LINE in ${LINE_BRANCHES[@]+"${LINE_BRANCHES[@]}"}; do
    FORK="$(git merge-base "$(remote "$DEFAULT_BRANCH")" "$(remote "$LINE")" 2>/dev/null)" || continue
    [[ "$FORK" == "$TAG_COMMIT" ]] && emit "$LINE" "forked from $DEFAULT_BRANCH at the tag"
  done
fi
case "$SUFFIX" in
  stable) CANDIDATES=(${LINE_BRANCHES[@]+"${LINE_BRANCHES[@]}"} "$DEFAULT_BRANCH") ;;
  next|next-internal) CANDIDATES=() ;;
  *) CANDIDATES=("$DEFAULT_BRANCH" ${LINE_BRANCHES[@]+"${LINE_BRANCHES[@]}"}) ;;
esac
for CANDIDATE in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  on_branch "$CANDIDATE" && emit "$CANDIDATE" "contains the tag"
done

BEST_BRANCH="$DEFAULT_BRANCH"
MAX_DISTANCE=999999
BEST_DISTANCE=$MAX_DISTANCE
BEST_REASON=""

if ! git rev-parse --verify "$(remote "$DEFAULT_BRANCH")" >/dev/null 2>&1; then
  echo "WARNING: default branch 'origin/$DEFAULT_BRANCH' not found on remote" >&2
fi

# A -next that the default branch holds was merged, and every branch forked
# from it since then holds the tag too, possibly hundreds. They all fail the
# fork check below at a few git calls each, so they are not listed: each holds
# a child of the tag commit from the default branch's history.
MAIN_HOLDS_TAG=""
FORKED_LATER=()
if [[ "$SUFFIX" == next* ]] && on_branch "$DEFAULT_BRANCH"; then
  MAIN_HOLDS_TAG=1
  for CHILD in $(git rev-list --parents "$TAG_COMMIT..$(remote "$DEFAULT_BRANCH")" |
                 awk -v tag="$TAG_COMMIT" '{ for (i = 2; i <= NF; i++) if ($i == tag) print $1 }'); do
    FORKED_LATER+=("--no-contains=$CHILD")
  done
fi

# Full ref names: the short form of refs/remotes/origin/HEAD is "origin".
# Only plain names, so the pick below never lands on one the payload rejects.
REMOTE_BRANCHES=""
for REMOTE_BRANCH in $(git for-each-ref --format='%(refname)' --contains="$TAG_COMMIT" \
                         ${FORKED_LATER[@]+"${FORKED_LATER[@]}"} refs/remotes/origin/ |
                       sed 's|^refs/remotes/origin/||'); do
  valid_branch "$REMOTE_BRANCH" && REMOTE_BRANCHES+="${REMOTE_BRANCHES:+$'\n'}$REMOTE_BRANCH"
done
if [[ "$SUFFIX" == next* ]]; then
  FEATURE_BRANCHES=""
  for REMOTE_BRANCH in $REMOTE_BRANCHES; do
    is_feature_branch "$REMOTE_BRANCH" && FEATURE_BRANCHES+="${FEATURE_BRANCHES:+$'\n'}$REMOTE_BRANCH"
  done
  [[ -n "$FEATURE_BRANCHES" ]] && REMOTE_BRANCHES="$FEATURE_BRANCHES"
fi

if [[ -z "$REMOTE_BRANCHES" && -n "$MAIN_HOLDS_TAG" ]]; then
  echo "No branch forked at this commit, falling back to '$DEFAULT_BRANCH', which holds the tag" >&2
  BEST_REASON="fallback, $DEFAULT_BRANCH holds the tag"
elif [ -z "$REMOTE_BRANCHES" ]; then
  echo "No remote branches contain this commit, falling back to '$DEFAULT_BRANCH'" >&2
  BEST_REASON="fallback, no remote branch holds the tag"
else
  echo "Remote branches containing this commit: $REMOTE_BRANCHES" >&2

  for REMOTE_BRANCH in $REMOTE_BRANCHES; do
    BRANCH_BASE=$(git merge-base "$(remote "$DEFAULT_BRANCH")" "$(remote "$REMOTE_BRANCH")" 2>/dev/null || echo "")

    if [ -n "$BRANCH_BASE" ]; then
      if git merge-base --is-ancestor "$BRANCH_BASE" "$TAG_COMMIT" 2>/dev/null; then
        DISTANCE=$(git rev-list --count "$TAG_COMMIT..$(remote "$REMOTE_BRANCH")")
        echo "Branch $REMOTE_BRANCH: distance from tip: $DISTANCE" >&2

        if [ "$DISTANCE" -lt "$BEST_DISTANCE" ]; then
          BEST_BRANCH=$REMOTE_BRANCH
          BEST_DISTANCE=$DISTANCE
          BEST_REASON="closest tip, distance: $DISTANCE"
        fi
      fi
    fi
  done

  if [ "$BEST_DISTANCE" -eq $MAX_DISTANCE ]; then
    # Step 2 already ruled the default branch out for every other suffix.
    if [[ -n "$MAIN_HOLDS_TAG" ]]; then
      echo "Distance algorithm found no match, falling back to '$DEFAULT_BRANCH', which holds the tag" >&2
      BEST_BRANCH="$DEFAULT_BRANCH"
      BEST_REASON="fallback, $DEFAULT_BRANCH holds the tag"
    else
      echo "Distance algorithm found no match, falling back to first branch" >&2
      # Not `head -n 1`: under pipefail a long list SIGPIPEs the echo.
      BEST_BRANCH="${REMOTE_BRANCHES%%$'\n'*}"
      BEST_REASON="first branch holding the tag"
    fi
  fi
fi

emit "$BEST_BRANCH" "$BEST_REASON"

#!/usr/bin/env bash
# Shared helpers for oss-commit-sync export.sh / import.sh.
#
# Both directions replay individual commits between a monorepo subtree and a
# downstream OSS repository, preserving author, date, and message, and linking
# the two histories with commit-message trailers:
#
#   Monorepo-Commit: <sha>   on OSS commits we created from monorepo commits
#   Oss-Commit: <sha>        on monorepo commits we created from OSS commits
#
# Trailers are the only sync state; there is no marker ref, map file, or
# external store. A commit that merely quotes a trailer string in its body is
# never matched: git's %(trailers) parsing only recognizes a well-formed
# trailer block, which is what interpret-trailers writes.

# shellcheck disable=SC2034  # used by the sourcing scripts
MONOREPO_TRAILER="Monorepo-Commit"
# shellcheck disable=SC2034  # used by the sourcing scripts
OSS_TRAILER="Oss-Commit"

# Committer identity for replayed commits (author identity is preserved from
# the source commit). Callers may override via the standard git env vars.
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-github-actions[bot]}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

emit() { echo "$1=$2" >> "${GITHUB_OUTPUT}"; }

die() {
  echo "::error::$1"
  exit 1
}

# newest_trailer_entry <ref> <key>
# Walk <ref> first-parent, newest first, and print "<commit-sha> <value>" for
# the first commit carrying the trailer. Prints nothing when none is found.
# With several same-key trailers on one commit the newest (last) value wins.
newest_trailer_entry() {
  local ref="$1" key="$2"
  git log --first-parent --format="%H%x09%(trailers:key=${key},valueonly,separator=%x09)" "$ref" \
    | awk -F'\t' 'NF >= 2 && $NF != "" { print $1 " " $NF; exit }'
}

# all_trailer_entries <ref> <key>
# Like newest_trailer_entry but prints every "<commit-sha> <value>" pair on
# the first-parent chain, newest first.
all_trailer_entries() {
  local ref="$1" key="$2"
  git log --first-parent --format="%H%x09%(trailers:key=${key},valueonly,separator=%x09)" "$ref" \
    | awk -F'\t' 'NF >= 2 && $NF != "" { print $1 " " $NF }'
}

# trailer_value <sha> <key>
# Print the trailer value of a single commit (newest wins); empty when absent.
trailer_value() {
  git log -1 --format="%(trailers:key=$2,valueonly)" "$1" | sed '/^[[:space:]]*$/d' | tail -n1
}

has_trailer() { [ -n "$(trailer_value "$1" "$2")" ]; }

# ensure_not_merge <sha>
# The replay model requires linear history on both sides (both repos have
# allow_merge_commit disabled). Fail loudly if a merge commit sneaks into the
# replay range instead of guessing which parent's diff to take.
ensure_not_merge() {
  local sha="$1"
  if [ "$(git rev-list --no-walk --count --merges "$sha")" -gt 0 ]; then
    die "commit ${sha} is a merge commit; the sync requires linear history"
  fi
}

# replay_commit <src-sha> <trailer-key> <git-dir>
# Commit whatever is currently staged in <git-dir>, preserving <src-sha>'s
# author name/email/date and full message, with "<trailer-key>: <src-sha>"
# appended as a proper trailer. The committer stays the CI identity.
replay_commit() {
  local src="$1" key="$2" dir="$3" msgfile author_name author_email author_date
  msgfile=$(mktemp)
  git log -1 --format=%B "$src" | git interpret-trailers --trailer "${key}: ${src}" > "$msgfile"
  IFS=$'\x1f' read -r author_name author_email author_date \
    < <(git log -1 --format='%an%x1f%ae%x1f%aI' "$src")
  GIT_AUTHOR_NAME="$author_name" \
  GIT_AUTHOR_EMAIL="$author_email" \
  GIT_AUTHOR_DATE="$author_date" \
    git -C "$dir" commit --quiet -F "$msgfile"
  rm -f "$msgfile"
}

# nothing_staged <git-dir>
# True when the index matches HEAD, i.e. a non-empty patch applied as a no-op
# because its content was already present (e.g. the same change landed on
# both sides). Callers skip such commits instead of letting `git commit`
# abort the run with "nothing to commit".
nothing_staged() {
  git -C "$1" diff --cached --quiet
}

# git_scrubbed <git args...>
# Run git with all output captured and OSS_REMOTE (which may embed a token in
# its URL) scrubbed before anything is echoed: git prints the remote URL on
# its "To <remote>" / "unable to access" lines. Actions secret-masking covers
# values that came from the secrets context; this covers the rest, matching
# the scrub convention in backport-legacy-split.
git_scrubbed() {
  local out rc=0
  out="$(git "$@" 2>&1)" || rc=$?
  [ -n "$out" ] && echo "${out//${OSS_REMOTE}/<oss-remote>}"
  return "$rc"
}

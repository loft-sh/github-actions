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
# external store.

# shellcheck disable=SC2034  # used by the sourcing scripts
MONOREPO_TRAILER="Monorepo-Commit"
# shellcheck disable=SC2034  # used by the sourcing scripts
OSS_TRAILER="Oss-Commit"

# Committer identity for replayed commits (author identity is preserved from
# the source commit). Callers may override via the standard git env vars.
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-github-actions[bot]}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
# Author defaults matter for the one commit not covered by replay_commit's
# per-commit author env: the export alignment commit (git commit-tree). On a
# bare CI runner with no user.name configured, git refuses to invent an
# author ("empty ident name"), so default the author to the bot identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$GIT_COMMITTER_NAME}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$GIT_COMMITTER_EMAIL}"

emit() { echo "$1=$2" >> "${GITHUB_OUTPUT}"; }

die() {
  echo "::error::$1"
  exit 1
}

# --- trailer lookup ----------------------------------------------------------
#
# Deliberately NOT git's own %(trailers) parsing. Git recognizes only the LAST
# paragraph of a message as the trailer block, and GitHub's "Squash and merge"
# appends "Co-authored-by:" lines as a NEW paragraph. That pushes a trailer we
# wrote out of the block git will parse: the line is still in the message
# verbatim, but %(trailers) stops seeing it, so the sync silently loses its
# resume point and re-walks history it already holds. Not hypothetical: it
# froze the vcluster-pro import anchor for a week, then hard-failed once one of
# the re-walked commits stopped applying as a no-op.
#
# So the scan reads the whole message. What keeps that safe from prose that
# merely mentions a trailer is the value shape: every trailer this action reads
# or writes carries a commit sha and nothing else, so the line must start at
# column 0 with the exact key and be followed only by hex. The key match is
# case-insensitive, matching git's own trailer semantics.

# Shortest abbreviation accepted from a hand-written trailer. Below this a hex
# run is too generic to be confidently a sha.
TRAILER_SHA_MIN_LEN=7

# trailer_entries <key> <git-log-args...>
# Print "<commit-sha> <value>" for every commit in the log that carries <key>,
# in log order. With several same-key lines on one commit the last one wins:
# GitHub's squash concatenates the branch's commit messages, so the last
# occurrence is the newest import.
#
# The awk consumer must NOT `exit` on the first match: closing the pipe early
# while `git log` is still writing a large history makes git receive SIGPIPE,
# and under `set -o pipefail` that surfaces as exit 141 (git's SIGPIPE handling
# is build-dependent, so this only bites on big repos on some runners). It
# reads the whole stream instead; callers keep the entries they want.
#
# Commits are framed by a leading \001 on the header line rather than an awk
# RS: a NUL or control-char RS is not portable across awk implementations
# (mawk treats an empty RS as paragraph mode), and a control character cannot
# occur at column 0 of a real commit message.
trailer_entries() {
  local key="$1"
  shift
  git log --format="%x01%H%n%B" "$@" | awk -v key="$key" -v minlen="$TRAILER_SHA_MIN_LEN" '
    function flush() {
      if (sha != "" && value != "") print sha " " value
      sha = ""
      value = ""
    }
    BEGIN { prefix = tolower(key) ": "; plen = length(prefix) }
    substr($0, 1, 1) == "\001" { flush(); sha = substr($0, 2); next }
    {
      line = $0
      sub(/[ \t\r]+$/, "", line)
      if (tolower(substr(line, 1, plen)) != prefix) next
      candidate = substr(line, plen + 1)
      if (candidate ~ /^[0-9a-f]+$/ && length(candidate) >= minlen && length(candidate) <= 40) {
        value = candidate
      }
    }
    END { flush() }'
}

# all_trailer_entries <ref-or-range> <key>
# Every "<commit-sha> <value>" pair on the first-parent chain, newest first.
all_trailer_entries() {
  trailer_entries "$2" --first-parent "$1"
}

# newest_trailer_entry <ref> <key>
# Print "<commit-sha> <value>" for the newest first-parent commit carrying the
# trailer. Prints nothing when none does.
newest_trailer_entry() {
  all_trailer_entries "$1" "$2" | awk 'NR == 1'
}

# trailer_value <sha> <key>
# Print the trailer value of a single commit (last wins); empty when absent.
trailer_value() {
  trailer_entries "$2" -1 "$1" | awk 'NR == 1 { print $2 }'
}

has_trailer() { [ -n "$(trailer_value "$1" "$2")" ]; }

# --- shared subtree / anchor helpers ------------------------------------------

# build_excludes
# Populate the global `excludes` array with :(exclude) pathspecs from the
# newline-separated EXCLUDE_PATHS. Expand it at call sites as
# `${excludes[@]+"${excludes[@]}"}` so an empty array is safe under `set -u`.
# The explicit `return 0` is load-bearing: with an empty EXCLUDE_PATHS the loop
# body's last command is a failed test, and a function returning that status is
# a failing call under `set -e` (unlike the same loop written inline, which
# bash exempts as a compound command).
build_excludes() {
  excludes=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && excludes+=(":(exclude)${p}")
  done <<< "${EXCLUDE_PATHS:-}"
  return 0
}

# external_is_benign <oss-sha>
# True when the commit's post-image (minus EXCLUDE_PATHS) is already present in
# the subtree, so mirroring on top of it cannot lose content. Covers the two
# externals the import direction deliberately skips without a trailer:
# excluded-paths-only commits, and changes that landed identically on both
# sides (import applied them as a no-op). Renames are inspected without -M so
# they decompose into delete+add and get checked path by path. A false "benign"
# cannot corrupt the mirror: the export convergence assertion still fails the
# run before pushing if OSS actually holds content the subtree lacks.
#
# Reads SUBTREE_PREFIX and the `excludes` array; compares against HEAD.
external_is_benign() {
  local s="$1" status path blob_oss blob_staging changes
  # Captured rather than piped from a process substitution: this function
  # answers "already present, safe to skip", so a producer failure invisible to
  # `set -e` would run the loop zero times and return "benign", silently
  # skipping a commit that actually needed importing. Fail closed instead.
  changes="$(git diff-tree --no-commit-id --name-status -r "$s" -- . ${excludes[@]+"${excludes[@]}"})" \
    || return 1
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    if [ "$status" = "D" ]; then
      # Deletion is benign only if the path is gone from staging too.
      if git cat-file -e "HEAD:${SUBTREE_PREFIX}/${path}" 2>/dev/null; then
        return 1
      fi
      continue
    fi
    blob_oss="$(git rev-parse --quiet --verify "${s}:${path}" 2>/dev/null)" || return 1
    blob_staging="$(git rev-parse --quiet --verify "HEAD:${SUBTREE_PREFIX}/${path}" 2>/dev/null)" || return 1
    [ "$blob_oss" = "$blob_staging" ] || return 1
  done <<< "$changes"
  return 0
}

# subtree_matches <oss-sha>
# True when the subtree at HEAD holds exactly that OSS commit's content
# (ignoring EXCLUDE_PATHS). Everything up to that commit is then already
# represented in the subtree, whatever the recorded trailers say.
#
# Reads SUBTREE_PREFIX and the `excludes` array.
subtree_matches() {
  local oss_sha="$1" staging_tree
  staging_tree="$(git rev-parse "HEAD:${SUBTREE_PREFIX}")" || return 1
  git diff --quiet "$oss_sha" "$staging_tree" -- . ${excludes[@]+"${excludes[@]}"}
}

# content_anchor <resume> <oss-tip>
# Print the newest OSS commit in <resume>..<oss-tip> whose content the subtree
# already holds, or nothing when there is none.
#
# This is what makes the anchor self-healing. A trailer is a *record* of an
# import, but the subtree tree is *evidence* of it, and evidence cannot be lost
# by a squash, a hand-edited message, or a hand-made import that forgot the
# trailer. Advancing the anchor to the newest commit the subtree already matches
# therefore repairs damaged trailer state on every run, with no marker commit,
# no repair PR, and no operator action.
#
# Safe by construction: if the subtree equals commit C's content, replaying
# anything up to C could only produce a no-op or a spurious conflict against a
# later change that is also already present. Commits after C are untouched and
# still imported normally, so nothing is ever skipped silently.
#
# Walks newest-first and returns the first match, so the common healthy case
# (subtree already at the tip) costs one comparison.
content_anchor() {
  local resume="$1" oss_tip="$2" c candidates
  # Returns non-zero on a git failure so callers can choose: the import must
  # fail closed, the advisory health report must degrade to a warning.
  candidates="$(git rev-list --first-parent "${resume}..${oss_tip}")" || return 1
  while read -r c; do
    [ -n "$c" ] || continue
    if subtree_matches "$c"; then
      echo "$c"
      return 0
    fi
  done <<< "$candidates"
  return 0
}

# resolve_import_anchor <oss-tip>
# The single definition of where an import resumes. Both the import and the
# health direction call it, so the two can never disagree about where the sync
# stands, which matters most in exactly the damaged-state cases health exists to
# diagnose.
#
# Results are returned in globals rather than on stdout, and the function MUST
# therefore be called plainly, never in a command substitution: a subshell would
# discard every one of them. Returns non-zero only when git itself failed, so
# the import can fail closed while the advisory health report degrades.
#
#   IMPORT_ANCHOR           where to resume (after seed floor and healing);
#                           empty when nothing identifies a starting point
#   IMPORT_ANCHOR_RECORDED  what the trailers alone record, before healing
#   IMPORT_ANCHOR_HEALED    how many commits healing advanced over
#   IMPORT_ANCHOR_SAW_TRAILER  true when any Oss-Commit trailer exists, so
#                           callers can tell "never synced" from "recorded
#                           anchor no longer reachable on OSS"
#   IMPORT_ANCHOR_SEED_BAD  true when SEED_OSS_COMMIT was set but is not a
#                           commit reachable from the OSS tip
#
# Resolution order:
#  1. the recorded import that reaches FARTHEST along OSS history, not the one on
#     the newest monorepo commit. Those differ when a trailer is lost or when an
#     older OSS commit is imported by hand after a newer one; taking the newest
#     would move the anchor BACKWARDS and re-walk commits already in the subtree.
#  2. SEED_OSS_COMMIT as a floor, so an operator can re-anchor without rewriting
#     history.
#  3. content healing (see content_anchor), which reconciles the record against
#     the evidence in the subtree.
resolve_import_anchor() {
  local oss_tip="$1" best="" candidate entries healed
  IMPORT_ANCHOR=""
  IMPORT_ANCHOR_RECORDED=""
  IMPORT_ANCHOR_HEALED=0
  IMPORT_ANCHOR_SAW_TRAILER=false
  IMPORT_ANCHOR_SEED_BAD=false

  # Captured first so a failing producer is observed: inside `done < <(...)` a
  # non-zero exit is invisible to `set -e`, and the loop would just run zero
  # times and report "no anchor" as if the branch had never synced.
  entries="$(all_trailer_entries HEAD "$OSS_TRAILER")" || return 1

  while read -r _ candidate; do
    [ -n "$candidate" ] || continue
    IMPORT_ANCHOR_SAW_TRAILER=true
    git cat-file -e "${candidate}^{commit}" 2>/dev/null || continue
    git merge-base --is-ancestor "$candidate" "$oss_tip" 2>/dev/null || continue
    if [ -z "$best" ] || git merge-base --is-ancestor "$best" "$candidate"; then
      best="$candidate"
    fi
  done <<< "$entries"
  IMPORT_ANCHOR_RECORDED="$best"

  if [ -n "${SEED_OSS_COMMIT:-}" ]; then
    if git cat-file -e "${SEED_OSS_COMMIT}^{commit}" 2>/dev/null \
      && git merge-base --is-ancestor "$SEED_OSS_COMMIT" "$oss_tip" 2>/dev/null; then
      if [ -z "$best" ] || git merge-base --is-ancestor "$best" "$SEED_OSS_COMMIT"; then
        best="$SEED_OSS_COMMIT"
      fi
    else
      IMPORT_ANCHOR_SEED_BAD=true
    fi
  fi

  [ -n "$best" ] || return 0

  healed="$(content_anchor "$best" "$oss_tip")" || return 1
  if [ -n "$healed" ] && [ "$healed" != "$best" ]; then
    IMPORT_ANCHOR_HEALED="$(git rev-list --count --first-parent "${best}..${healed}")"
    best="$healed"
  fi
  IMPORT_ANCHOR="$best"
  return 0
}

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

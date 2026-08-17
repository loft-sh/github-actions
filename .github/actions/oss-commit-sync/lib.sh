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
# Not git's %(trailers) parsing ALONE, and not the whole-message scan alone. Each
# misses records the other sees, so the lookup is the union of both.
#
# Git recognizes only the LAST paragraph of a message as the trailer block, and
# GitHub's "Squash and merge" appends "Co-authored-by:" lines as a NEW paragraph.
# That pushes a trailer we wrote out of the block git will parse: the line is
# still in the message verbatim, but %(trailers) stops seeing it, so the sync
# silently loses its resume point and re-walks history it already holds. Not
# hypothetical: it froze the vcluster-pro import anchor for a week, then
# hard-failed once one of the re-walked commits stopped applying as a no-op.
#
# The other way round, git's parser is laxer about the line itself: it accepts
# "Key:<sha>" with no space, with a tab, with several spaces, and uppercase hex,
# none of which the body scan matches. A record git reads perfectly would otherwise
# be invisible, which deadlocked the export from the opposite direction, so
# trailer_scan reads git's block as well and returns the union.
#
# The scan's value shape is what keeps most prose out: every trailer this action
# reads or writes carries a commit sha and nothing else, so the line must start at
# column 0 with the exact key and be followed only by hex. It reduces accidental
# matches rather than ruling them out, and a line of that exact shape quoted in a
# body does match, so callers that draw a conclusion about a human's behaviour
# from a match (health's squash detector) corroborate it against OSS history
# first. The key match is case-insensitive, matching git's own trailer semantics.

# Shortest abbreviation accepted from a hand-written trailer. Below this a hex
# run is too generic to be confidently a sha.
TRAILER_SHA_MIN_LEN=7

# The frame delimiter trailer_scan builds its git-log format from. 32 hex, read
# from the kernel pool two different ways before falling back to $RANDOM (see
# the tiers below) for a runner that offers neither.
#
# Drawn once per process rather than per call: trailer_scan runs once per commit
# inside three O(n) walks (the export divergence guard, health's pending loop,
# classify_healed_range), and two extra forks each would be paid n times over for
# nothing. Every commit these scripts read was written before this process
# started -- replay_commit only copies messages that already existed -- so a
# per-process mark is exactly as unguessable as a per-call one.
TRAILER_FRAME_MARK="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || TRAILER_FRAME_MARK=""
if [ "${#TRAILER_FRAME_MARK}" -ne 32 ]; then
  # Still the kernel's pool, just reached another way. The redirection is inside
  # the braces so 2>/dev/null covers it: bash applies redirections left to right
  # and reports a failed INPUT redirection before the stderr one is in effect, so
  # the obvious spelling prints a bare "No such file or directory" on a runner
  # with no /proc -- into the health direction's log, whose whole contract is that
  # an advisory run stays clean.
  TRAILER_FRAME_MARK="$({ tr -d '\n-' < /proc/sys/kernel/random/uuid; } 2>/dev/null)" || TRAILER_FRAME_MARK=""
fi
if [ "${#TRAILER_FRAME_MARK}" -ne 32 ]; then
  # Last resort, and weaker on purpose rather than by accident: $RANDOM is a PRNG
  # seeded from time and pid, so a determined attacker who could both force this
  # branch and enumerate that state could aim at the frame. Reaching it means the
  # kernel pool was unavailable twice, which on the runners this action targets
  # does not happen; failing the sync outright would trade a real outage for a
  # theoretical attack.
  TRAILER_FRAME_MARK="$(printf '%04x%04x%04x%04x%04x%04x%04x%04x' \
    "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")"
fi

# trailer_scan <key> <multi> <git-log-args...>
# Print "<commit-sha> <value>" per match. With multi=0 a commit carrying several
# same-key lines yields one entry, the last record winning; with multi=1 it yields
# one entry per distinct value. Callers pick by what they are asking: "which record
# is newest" wants last-wins, "was this ever recorded" wants all.
#
# multi=1 order is body-scan values in message order, then any value only git's
# parser saw. Treat the output as a SET: it is not a reliable message ordering, and
# no caller may take its first or last line to mean anything.
#
# The awk consumer must NOT `exit` on the first match: closing the pipe early
# while `git log` is still writing a large history makes git receive SIGPIPE,
# and under `set -o pipefail` that surfaces as exit 141 (git's SIGPIPE handling
# is build-dependent, so this only bites on big repos on some runners). It
# reads the whole stream instead; callers keep the entries they want.
#
# Records are framed by TRAILER_FRAME_MARK, drawn once when this file is sourced,
# rather than an awk RS: a NUL or control-char RS is not portable across awk
# implementations (mawk treats an empty RS as paragraph mode).
#
# It has to be unpredictable, not merely unusual. Framing on a fixed control byte
# is forgeable, because every byte except NUL is legal in a commit message and
# import.sh replays OSS messages into the monorepo verbatim: a body line holding
# the delimiter reopened the frame mid-record, and the bare hex line after it was
# read as a block value, putting a sha into the absorbed set with no trailer key
# present anywhere. Every commit these scripts read was written before this
# process drew the mark, so nothing readable can contain it: the frame cannot be
# forged rather than merely being awkward to.
#
# Both readings come from THIS function, and nowhere else. Keeping them in separate
# callers meant "is this commit a record" had two answers, and every caller had to
# remember to ask both. It did not stay consistent: a commit counted as absorbed by
# one reading and not OSS-originated by the other was replayed back to OSS,
# resurrecting content the mirror had moved past. One function, one answer, so a new
# caller cannot get it wrong.
#
# Block values are held back and applied AFTER the body scan, because git's block is
# by definition the message's final trailer paragraph: anything in it comes later
# than any body line above it. So for multi=0 a block value wins, which is what
# last-wins means and what the import anchor reads as "newest". Emitting them first
# instead let an earlier, well-formed body line overwrite the genuinely final record
# and move the anchor forward past commits still waiting to be imported.
#
# A well-formed trailer is seen by both readings; the duplicate is dropped per
# commit so the output stays a clean set.
#
# The body half is not applied to every key -- see trailer_reads_body.

# trailer_reads_body <key>
# True when the whole-message scan applies to this key, false when only git's own
# trailer block may be trusted.
#
# The union above exists for ONE reason: a record we wrote can be orphaned from
# git's block by a squash. That happens to Oss-Commit, which is written on the
# monorepo side and reaches the base branch through a PR that GitHub may squash.
#
# It cannot happen to Monorepo-Commit. Export writes that trailer itself and
# pushes the commit straight to OSS -- no PR, no squash, no merge method, nothing
# between writing it and it being in the block. So the body scan buys that key
# nothing, and it costs: OSS is a public repository taking outside contributions,
# so an external commit's message is contributor-controlled, and a column-zero
# "Monorepo-Commit: <any valid monorepo sha>" line in a body would otherwise be
# read as ours. That commit then becomes the export anchor, which puts it BEFORE
# the divergence range so it is never checked, while the import loop guard skips
# it as something we created. Export cannot converge because it was never
# absorbed, the import refuses to absorb it, and with align-tree the false anchor
# authorises deleting its content from OSS instead.
#
# So the trust follows the threat: unioned where our own records can be orphaned,
# block-only where they cannot and the body is someone else's to write.
#
# READ THIS BEFORE TRUSTING THE ABOVE. This narrows the forgery, it does not end
# it. The same line written as a REAL trailer -- last paragraph of the message,
# where git's own parser reads it -- is still accepted, because at this layer
# there is nothing to tell it apart from a record we wrote: both are a valid
# monorepo sha under the right key in the right place. Verified on this branch:
# with align-tree the forged anchor still deletes the contributor's file from the
# mirror and the run reports diverged=false and exits 0.
#
# What is closed is the variant that survives a squash, which is the one a
# contributor gets for free by writing the line anywhere in a PR description.
#
# Closing the rest needs evidence this layer does not have: not the committer
# name, which is not authentication -- anyone constructing a commit can set the
# bot's -- but something the object proves, a verified signature or auditable
# push provenance, plus a trusted cutoff for the OSS history that predates it.
# That is a change to what the sync treats as authentic, not to how it reads a
# trailer. Until then the exposure is real and stated, not implied away.
trailer_reads_body() {
  # Case-folded, because trailer_scan matches keys case-insensitively "matching
  # git's own trailer semantics" and this decides a trust boundary: compared
  # exactly, a caller spelling the key "monorepo-commit" would silently re-enable
  # the body scan for the one key that must not have it.
  [ "${1,,}" != "${MONOREPO_TRAILER,,}" ]
}

trailer_scan() {
  local key="$1" multi="$2"
  shift 2
  local mark="$TRAILER_FRAME_MARK" bodyscan=0
  trailer_reads_body "$key" && bodyscan=1
  git log --format="${mark}H%H%n%(trailers:key=${key},valueonly,unfold)${mark}B%n%B" "$@" \
    | awk -v key="$key" -v minlen="$TRAILER_SHA_MIN_LEN" -v multi="$multi" -v mark="$mark" \
          -v bodyscan="$bodyscan" '
    function shaped(candidate) {
      return (candidate ~ /^[0-9a-f]+$/ && length(candidate) >= minlen && length(candidate) <= 40)
    }
    function take(candidate) {
      if (!shaped(candidate)) return
      if (multi == 1) {
        if (seen[candidate]++) return
        print sha " " candidate
      }
      else value = candidate
    }
    # A body line is only taken once the NEXT line has been seen, because that is
    # the earliest point at which we know it was not folded.
    function body_take() {
      if (pending != "") { take(pending); pending = "" }
    }
    function flush() {
      # The held-back block values, applied last: they sit in the final paragraph
      # of the message, so they are its latest records.
      if (sha != "") {
        body_take()
        for (i = 1; i <= nblock; i++) take(block[i])
        if (value != "") print sha " " value
      }
      sha = ""
      value = ""
      pending = ""
      nblock = 0
      delete block
      delete seen
    }
    BEGIN {
      keyname = tolower(key); klen = length(keyname)
      hdr = mark "H"; hlen = length(hdr); blkend = mark "B"
      inblock = 0; nblock = 0
    }
    # No length test on what follows: the delimiter already makes this line
    # unforgeable, so whatever git printed for %H is the sha, whichever hash the
    # repository uses.
    substr($0, 1, hlen) == hdr {
      flush(); sha = substr($0, hlen + 1); inblock = 1; next
    }
    # Whole-line match, not a prefix: git preserves a trailer value verbatim, and a
    # prefix test would end the block on any value that merely starts the same way,
    # hiding every parser-only record below it. (No apostrophes in here: the awk
    # program is a single-quoted shell string.)
    $0 == blkend { inblock = 0; next }
    inblock {
      # Already key-stripped and unfolded by git, so a folded value arrives whole
      # and fails the shape test rather than donating its first line. Lowercased
      # because git accepts uppercase hex and the shas we compare against do not.
      line = tolower($0)
      sub(/[ \t\r]+$/, "", line)
      if (shaped(line)) block[++nblock] = line
      next
    }
    # Everything below reads the message body. For a key whose records cannot be
    # squash-orphaned there is nothing down there to recover, and the body is
    # contributor-controlled, so it is not read at all.
    !bodyscan { next }
    # A continuation line, so whatever we were holding was a folded value rather
    # than a bare sha. Dropping it here is what makes the body scan agree with the
    # unfolded block reading; keeping only its first line promoted a sha nobody
    # recorded, which is the one direction of disagreement that can lose content.
    #
    # It must carry something other than whitespace to count: git leaves the value
    # above a blank-but-indented line intact, so treating that line as a fold would
    # drop a record git reads perfectly.
    /^[ \t]/ && /[^ \t\r]/ { pending = ""; next }
    {
      body_take()
      line = $0
      sub(/[ \t\r]+$/, "", line)
      # Separator and case follow git, not our own stricter spelling: git reads
      # "Key:<sha>", a tab, several spaces, whitespace BEFORE the colon, and
      # uppercase hex. A record in any of those forms is invisible to git the
      # moment a squash orphans it from the block, and reading those is the whole
      # reason this scan exists. The colon is still required, so a longer key that
      # merely starts with this one does not match.
      low = tolower(line)
      if (substr(low, 1, klen) != keyname) next
      rest = substr(low, klen + 1)
      sub(/^[ \t]+/, "", rest)
      if (substr(rest, 1, 1) != ":") next
      rest = substr(rest, 2)
      sub(/^[ \t]+/, "", rest)
      pending = rest
    }
    END { flush() }'
}

# trailer_entries <key> <git-log-args...>
# Print "<commit-sha> <value>" for every commit in the log that carries <key>,
# in log order. With several same-key lines on one commit the last one wins:
# GitHub's squash concatenates the branch's commit messages, so the last
# occurrence is the newest import.
trailer_entries() {
  local key="$1"
  shift
  trailer_scan "$key" 0 "$@"
}

# all_trailer_entries <ref-or-range> <key>
# Every "<commit-sha> <value>" pair on the first-parent chain, newest first.
all_trailer_entries() {
  trailer_entries "$2" --first-parent "$1"
}

# every_trailer_value <ref-or-range> <key>
# Every value recorded anywhere on the first-parent chain, newest commit first.
# Within one commit the order is unspecified (see trailer_scan): this is a set.
# Never use it to pick "the newest record", which is what newest_trailer_entry
# answers.
#
# This is the set-membership question, "is this sha recorded at all", and it
# must not use last-wins. A squash-merged import PR that replayed N commits
# carries N same-key lines on one commit, and last-wins would report only the
# newest, leaving the other N-1 looking unrecorded forever. That is not
# theoretical: it deadlocked the vcluster-pro export for a week, because the
# content fallback misses too whenever one of the hidden commits was reverted
# upstream inside the same import.
every_trailer_value() {
  trailer_scan "$2" 1 --first-parent "$1" | awk '{print $2}'
}

# resolve_sha_set
# Read candidate shas on stdin; print each one, plus its full 40-char form
# whenever an abbreviation resolves to a commit in this repo.
#
# Membership sets built from trailer values are compared against shas that come
# out of `git rev-list` full-length, while a trailer value need only be a hex run
# of TRAILER_SHA_MIN_LEN or more: a hand-written or shortened record therefore
# never matches, and the commit it absorbed reads as unabsorbed forever. Same
# deadlock every_trailer_value exists to fix, reached by the other road.
#
# Resolution is prefix-checked, so a resolved sha can only ever be the commit
# the trailer names: `^{commit}` also peels an annotated tag object to a commit
# sharing none of its digits, which would put a commit nobody recorded into the
# set. Widening the set is NOT harmless here. The guard is the only thing
# standing between an unabsorbed external commit and align-tree=true, which
# converges by overwriting the OSS tree rather than by failing, so a commit
# wrongly believed absorbed can have its content flattened out of OSS.
#
# Values that are already full length are passed through without a lookup: every
# trailer this action writes is one, so the normal case spawns no git at all.
# Unresolvable values are printed verbatim too, keeping a trailer that names a
# commit this repo does not hold matching literally as before.
resolve_sha_set() {
  local v full rc
  # `|| [ -n "$v" ]` so a final line with no trailing newline is not dropped:
  # losing a sha here is the same deadlock class this function exists to close.
  while IFS= read -r v || [ -n "$v" ]; do
    [ -n "$v" ] || continue
    printf '%s\n' "$v"
    [ "${#v}" -lt 40 ] || continue
    rc=0
    full="$(resolve_commit_prefix "$v")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$full"
    elif [ "$rc" -eq 2 ]; then
      # A broken git must not quietly shrink the absorbed set. That reports an
      # absorbed commit as unabsorbed and sends the operator after a divergence
      # that is not there, which is this action's most expensive failure to
      # diagnose. Returning non-zero aborts the caller under pipefail instead.
      echo "::error::git failed while resolving the trailer record ${v}; refusing to judge divergence on an incomplete absorbed set" >&2
      return 1
    fi
  done
}

# lines_contain <haystack> <needle>
# True when <needle> equals one whole line of <haystack>.
#
# A here-string, not printf into a pipe: grep -q exits at the first match, and a
# haystack past the pipe buffer leaves the writer blocked, so it dies of SIGPIPE
# and pipefail turns a found value into a failed lookup. The caller reads that as
# "not present" and reports a clean commit as a squash.
lines_contain() {
  # -- so a needle that begins with a dash is a pattern rather than an option,
  # and an explicit empty-needle answer: the here-string always supplies a final
  # newline, so an empty haystack would otherwise report an empty needle present.
  [ -n "$2" ] || return 1
  grep -qxF -- "$2" <<< "$1"
}

# filter_sha_values
# Read candidate values on stdin; print those shaped like a commit sha, lowercased.
#
# Values taken from git's own %(trailers) have NOT been through trailer_scan's
# shape filter. They arrive already key-stripped and unfolded, so the line syntax
# git was lax about is gone by this point and only the value shape is left to
# check. Whatever a human wrote still reaches here, so it must not go to rev-parse
# unchecked, where reflog syntax like @{9999} exits 128 and resolve_sha_set
# escalates that into a failed export.
#
# Length bounds and the hex test rather than a regex interval, matching
# trailer_scan: awk interval support is not portable across implementations.
filter_sha_values() {
  awk -v minlen="$TRAILER_SHA_MIN_LEN" '
    { v = tolower($0) }
    v ~ /^[0-9a-f]+$/ && length(v) >= minlen && length(v) <= 40 { print v }'
}

# resolve_commit_prefix <value>
# Print the full sha of the commit <value> names and return 0. Return 1 when it
# names no commit here, and 2 when git itself failed. Callers MUST keep those two
# apart: "names no commit" is an ordinary answer about the value, while a git
# failure is no answer at all, and reading one as the other turns a broken repo
# into a clean report.
#
# Prefix-checked, because every caller is asking "which commit does this trailer
# name", never "what does this object point at": `^{commit}` peels an annotated
# tag object to a commit sharing none of the value's digits, and both
# `git merge-base --is-ancestor` and `git cat-file -e` peel one the same way.
#
# --quiet is not quiet on a type mismatch: an abbreviation that uniquely names a
# tree or blob still prints "expected commit type" to stderr, which would put a
# bare error line in an otherwise green log.
resolve_commit_prefix() {
  local full rc=0
  full="$(git rev-parse --verify --quiet "${1}^{commit}" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # rev-parse answers 1 for absent, ambiguous and type-mismatch alike, which
    # are all "names no commit". Anything else is git failing.
    [ "$rc" -eq 1 ] && return 1
    return 2
  fi
  case "$full" in
    "$1"*) printf '%s\n' "$full" ;;
    *) return 1 ;;
  esac
}

# map_lookup <key> <tsv-file>
# Print the second field of the first line whose first field equals <key>.
#
# Both operands are forced to strings before comparing. A field and a -v variable
# are both "strnum", so awk compares two all-decimal shas NUMERICALLY, as doubles:
# 1234...890 and 1234...891 differ past the 17th significant digit and therefore
# test equal, and the lookup returns the wrong row. Same trap the trailer scan hit
# when it ranked hex values; the fix is the same.
#
# `exit` is safe here in a way it is not in the trailer scan: the input is a file,
# not a pipe from a still-writing `git log`, so leaving early cannot SIGPIPE a
# producer.
map_lookup() {
  awk -F'\t' -v k="$1" '$1 "" == k "" { print $2; exit }' "$2"
}

# is_ancestor <maybe-ancestor> <descendant>
# Return 0 when it is one, 1 when it is not, and 2 when git itself failed.
#
# Same tripling as resolve_commit_prefix, and for the same reason: `merge-base
# --is-ancestor` answers 1 for "no" and 128 for "I could not tell you", and the
# bare `|| continue` that collapsed them let a broken object store quietly demote
# every candidate to "not reachable". resolve_import_anchor then returns success
# with an older anchor, or none at all, so the import re-walks absorbed commits
# or announces a history rewrite that never happened -- while health reports
# degraded=false, because nothing ever said anything went wrong.
is_ancestor() {
  local rc=0
  git merge-base --is-ancestor "$1" "$2" 2>/dev/null || rc=$?
  if [ "$rc" -le 1 ]; then
    return "$rc"
  fi
  return 2
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

# classify_healed_range <recorded-anchor> <healed-anchor>
# Split the commits the anchor advanced over into the two cases that produce an
# identical count but mean opposite things:
#
#   exports     commits we created ourselves (Monorepo-Commit trailer). They
#               never carry an Oss-Commit trailer, because that trailer records
#               an import and these went the other way. The anchor therefore
#               trails every export until the next import records a trailer past
#               them, and healing over them is the steady state, not a fault.
#   unrecorded  commits with neither trailer: an import whose provenance record
#               was lost (a squash that dropped the trailer, a hand-made import).
#               This is the only case worth an annotation.
#
# Results in globals HEALED_TOTAL, HEALED_EXPORTS, HEALED_UNRECORDED (the last
# two sum to the first). Returns non-zero on a git failure so callers can fail
# closed rather than under-report.
classify_healed_range() {
  local from="$1" to="$2" range c
  HEALED_TOTAL=0
  HEALED_EXPORTS=0
  HEALED_UNRECORDED=0
  # Captured rather than piped from a process substitution: `set -e` cannot see a
  # producer failure inside `done < <(...)`, so a broken rev-list would run the
  # loop zero times and report a healed range of nothing.
  range="$(git rev-list --first-parent "${from}..${to}")" || return 1
  while read -r c; do
    [ -n "$c" ] || continue
    HEALED_TOTAL=$((HEALED_TOTAL + 1))
    if has_trailer "$c" "$MONOREPO_TRAILER"; then
      HEALED_EXPORTS=$((HEALED_EXPORTS + 1))
    else
      HEALED_UNRECORDED=$((HEALED_UNRECORDED + 1))
    fi
  done <<< "$range"
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
#   IMPORT_ANCHOR_HEALED_EXPORTS     of those, how many we created ourselves
#                           (Monorepo-Commit trailer); expected, see
#                           classify_healed_range
#   IMPORT_ANCHOR_HEALED_UNRECORDED  of those, how many carry neither trailer,
#                           i.e. imports whose provenance record was lost
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
  local oss_tip="$1" best="" candidate entries healed rc seed_commit anc_rc seed_ok
  IMPORT_ANCHOR=""
  IMPORT_ANCHOR_RECORDED=""
  IMPORT_ANCHOR_HEALED=0
  IMPORT_ANCHOR_HEALED_EXPORTS=0
  IMPORT_ANCHOR_HEALED_UNRECORDED=0
  IMPORT_ANCHOR_SAW_TRAILER=false
  IMPORT_ANCHOR_SEED_BAD=false

  # multi=1, not the last-wins lookup: the loop below already picks the record
  # that reaches FARTHEST along OSS history, so it wants every candidate, and
  # narrowing to one per commit first throws away the very values it exists to
  # compare. A squash-merged import PR records every commit it replayed on one
  # commit, and if those lines are not in ancestry order the farther one is the
  # one discarded -- the anchor then lands behind a commit that is demonstrably
  # absorbed, content healing cannot reach it because the subtree matches no
  # single OSS commit, and the replay dies conflicting on work already imported.
  # Same wrong contract, and same deadlock, that every_trailer_value fixed on the
  # export side.
  #
  # Captured first so a failing producer is observed: inside `done < <(...)` a
  # non-zero exit is invisible to `set -e`, and the loop would just run zero
  # times and report "no anchor" as if the branch had never synced.
  entries="$(trailer_scan "$OSS_TRAILER" 1 --first-parent HEAD)" || return 1

  while read -r _ candidate; do
    [ -n "$candidate" ] || continue
    IMPORT_ANCHOR_SAW_TRAILER=true
    # Prefix-checked like the export guard's absorbed set: cat-file -e and
    # merge-base both peel an annotated tag object, so without this a value that
    # names no recorded commit can win `best`. The anchor decides where the
    # import starts, so a wrong winner skips real imports with nothing to show
    # for it: no replay, no conflict, no pending count.
    rc=0
    candidate="$(resolve_commit_prefix "$candidate")" || rc=$?
    if [ "$rc" -eq 2 ]; then
      return 1
    elif [ "$rc" -ne 0 ]; then
      continue
    fi
    anc_rc=0
    is_ancestor "$candidate" "$oss_tip" || anc_rc=$?
    if [ "$anc_rc" -eq 2 ]; then
      return 1
    elif [ "$anc_rc" -ne 0 ]; then
      continue
    fi
    if [ -z "$best" ]; then
      best="$candidate"
      continue
    fi
    anc_rc=0
    is_ancestor "$best" "$candidate" || anc_rc=$?
    if [ "$anc_rc" -eq 2 ]; then
      return 1
    elif [ "$anc_rc" -eq 0 ]; then
      best="$candidate"
    fi
  done <<< "$entries"
  IMPORT_ANCHOR_RECORDED="$best"

  if [ -n "${SEED_OSS_COMMIT:-}" ]; then
    # Peeled, then stored peeled. An operator naturally seeds with what
    # `git rev-parse v1.2.3` printed, which is the tag object; accepting that is
    # right, but keeping it is not. The anchor is compared against commit shas
    # elsewhere -- import's "$RESUME" = "$OSS_TIP" nothing-to-do shortcut, and
    # health's anchor output -- and a tag sha never equals any of them, so the
    # shortcut can never fire and every run replays an empty range.
    #
    # rev-parse answers 1 for absent, ambiguous and type-mismatch alike, which are
    # all "names no commit here" and a fair thing to blame the seed for. Reporting
    # a git failure as a bad seed instead sends the operator to re-check a value
    # that was right all along.
    #
    # But 1 is not the only bad-seed code, and this is the one lookup where that
    # matters. Revision syntax git refuses to parse at all -- the reflog spellings
    # `@{9999}` and `HEAD@{99}` -- exits 128, the same code a broken repository
    # returns, and unlike a trailer value the seed reaches here unfiltered by any
    # shape test (see filter_sha_values, which exists to keep exactly those out of
    # rev-parse). So corroborate before blaming either: ask git something we
    # already know the answer to, and only call it broken if it gets that wrong
    # too. Otherwise git is fine and the seed is simply unusable.
    rc=0
    seed_commit="$(git rev-parse --verify --quiet "${SEED_OSS_COMMIT}^{commit}" 2>/dev/null)" || rc=$?
    if [ "$rc" -gt 1 ]; then
      if git rev-parse --verify --quiet "${oss_tip}^{commit}" >/dev/null 2>&1; then
        rc=1
      else
        return 1
      fi
    fi
    seed_ok=false
    if [ "$rc" -eq 0 ]; then
      anc_rc=0
      is_ancestor "$seed_commit" "$oss_tip" || anc_rc=$?
      if [ "$anc_rc" -eq 2 ]; then
        return 1
      elif [ "$anc_rc" -eq 0 ]; then
        seed_ok=true
      fi
    fi
    if [ "$seed_ok" = "true" ]; then
      if [ -z "$best" ]; then
        best="$seed_commit"
      else
        anc_rc=0
        is_ancestor "$best" "$seed_commit" || anc_rc=$?
        if [ "$anc_rc" -eq 2 ]; then
          return 1
        elif [ "$anc_rc" -eq 0 ]; then
          best="$seed_commit"
        fi
      fi
    else
      IMPORT_ANCHOR_SEED_BAD=true
    fi
  fi

  [ -n "$best" ] || return 0

  healed="$(content_anchor "$best" "$oss_tip")" || return 1
  if [ -n "$healed" ] && [ "$healed" != "$best" ]; then
    classify_healed_range "$best" "$healed" || return 1
    IMPORT_ANCHOR_HEALED="$HEALED_TOTAL"
    IMPORT_ANCHOR_HEALED_EXPORTS="$HEALED_EXPORTS"
    IMPORT_ANCHOR_HEALED_UNRECORDED="$HEALED_UNRECORDED"
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

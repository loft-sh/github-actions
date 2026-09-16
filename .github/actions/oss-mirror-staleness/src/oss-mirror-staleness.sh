#!/usr/bin/env bash
set -euo pipefail

# Is the downstream OSS mirror carrying every subtree commit the monorepo has?
#
# The export fails closed and stops, which is correct but invisible: it runs on
# push, so a failure leaves a red run in the Actions tab while the mirror quietly
# stops advancing. Comparing the refs instead of reading run history also catches
# an export that stopped triggering at all.
#
# Method: each exported commit carries a Monorepo-Commit trailer naming its
# source. Collect those from the OSS branch, walk the monorepo branch's
# subtree-touching commits newest first, and the first one that is recorded is
# the frontier; everything newer is backlog. Trailer reading is permissive on
# purpose, because a record we fail to read invents backlog that is not there.
#
# Advisory: this never exits non-zero, since silence is the failure it exists to
# catch and it must not become a new way to fail quietly. When it cannot answer
# it sets degraded, and CALLERS MUST ALERT ON degraded AS WELL AS stale.
#
# Required env: SUBTREE_PREFIX, OSS_REMOTE, OSS_REPO, BRANCH.
# Optional env: EXCLUDE_PATHS, MAX_AGE_HOURS, SCAN_LIMIT, GITHUB_OUTPUT,
# GITHUB_STEP_SUMMARY.

# Defaulted rather than asserted with ${VAR:?}, which aborts with status 1 before
# a single output exists: a caller gating on stale or degraded would then see
# neither, which is the silence this check was written to break. main validates
# them through degrade instead.
SUBTREE_PREFIX="${SUBTREE_PREFIX:-}"
# A trailing slash silently changes what pathspecs match, so settle the
# spelling once, here, rather than at each use.
SUBTREE_PREFIX="${SUBTREE_PREFIX%"${SUBTREE_PREFIX##*[!/]}"}"
OSS_REMOTE="${OSS_REMOTE:-}"
# OSS_REMOTE carries the token in its URL, so nothing human-facing may print it.
OSS_REPO="${OSS_REPO:-}"
BRANCH="${BRANCH:-}"
EXCLUDE_PATHS="${EXCLUDE_PATHS:-}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-24}"
SCAN_LIMIT="${SCAN_LIMIT:-500}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Namespaced so the fetch cannot collide with a real remote-tracking ref in the
# caller's checkout. Nothing reads it before main has rejected an empty BRANCH.
FETCH_REF="refs/oss-mirror-staleness/${BRANCH}"

emit() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT}"; }

summary_heading_written=""

# Several paths say two things (a merge blocker and then the staleness verdict),
# and a heading per call renders as the same H3 two or three times with a
# fragment under each. Braces, not a subshell, so the flag survives the call.
summarize() {
  {
    if [ -z "${summary_heading_written}" ]; then
      echo "### OSS mirror staleness: \`${OSS_REPO}\` \`${BRANCH}\`"
      echo
      summary_heading_written=1
    fi
    echo "$1"
    echo
  } >>"${GITHUB_STEP_SUMMARY}"
}

# Fail-safe: whatever we could not determine, say so rather than reporting a
# clean bill of health. Every early return goes through here.
degrade() {
  echo "::warning::${1}"
  emit degraded true
  summarize "Could not determine mirror staleness: ${1}"
  exit 0
}

validate_numeric() {
  local name="$1" value="$2"
  # Bound the length before any arithmetic: a long digit string overflows and
  # wraps, which silently changes the comparison it feeds.
  if [[ ! "$value" =~ ^[0-9]{1,9}$ ]] || [ "$((10#$value))" -lt 1 ]; then
    echo "::warning::${name} must be a positive integer under 10 digits, got '${value//[^[:print:]]/ }'"
    return 1
  fi
}

# The paths the export never mirrors, as pathspecs. Same list the exporter is
# given: it holds the OSS tree and the subtree tree to agree everywhere else and
# says so, so a tree comparison here that demanded equality everywhere would
# never match on any repo that configures them.
build_excludes() {
  excludes=()
  local path
  while IFS= read -r path; do
    [ -n "${path}" ] && excludes+=(":(exclude)${path}")
  done <<<"${EXCLUDE_PATHS}"
  return 0
}

# A caller reading `stale` after a degraded run must get a real answer, not an
# empty string that compares equal to nothing.
emit_defaults() {
  emit stale false
  emit degraded false
  emit backlog-count 0
  emit frontier ""
  emit oss-tip ""
  emit oldest-unmirrored ""
  emit oldest-unmirrored-age-hours 0
  emit export-unconfirmed false
}

# Git's trailer block only, never the message body, matching the exporter (see
# trailer_reads_body in oss-commit-sync lib.sh). OSS is public and takes outside
# contributions, so a body line is contributor-controlled: a column-zero
# "Monorepo-Commit: <sha>" in one would otherwise be read here as a record we
# wrote, and a record is what ends the backlog walk, so it would report a mirror
# that has stopped advancing as in sync.
#
# This narrows that, it does not end it, exactly as lib.sh says of the same key:
# the line written where git reads it, as the last paragraph, is still accepted,
# because at this layer nothing tells it apart from a record we wrote. What is
# closed is the variant a contributor gets for free by putting the line anywhere
# in a PR description, which a squash then leaves in the body. Closing the rest
# needs provenance this layer does not have; read the lib.sh comment for the
# whole statement rather than trusting this to be a boundary.
#
# Nothing legitimate is lost either way: replay_commit writes the trailer with
# `interpret-trailers --no-divider` precisely so it lands in the block, and
# export pushes straight to OSS with no PR and no squash in between. Unlike
# Oss-Commit, this key cannot be orphaned out of the block.
#
# Returns 0 with the values, 1 when there are none, 2 when git itself failed.
# Reading git inside the pipeline would hide its status behind grep's: under
# pipefail the rightmost non-zero wins, so a missing ref arrives as grep's
# no-match and gets the wrong diagnosis. Bounded because the frontier always sits
# near the tip, and an unbounded walk would read years of pre-merge OSS history.
read_recorded_anchors() {
  local values
  values="$(git log --max-count="$((10#$SCAN_LIMIT))" \
    --format='%(trailers:key=Monorepo-Commit,valueonly,unfold)' "${FETCH_REF}")" || return 2
  printf '%s\n' "${values}" |
    grep -oiE '^[0-9a-f]{7,64}$' |
    tr 'A-F' 'a-f' | sort -u
}

# The exporter skips commits that came from OSS and never records them, so
# counting one as backlog would alert forever on a mirror that is current.
#
# Reading more strictly than the exporter is not the safe direction it looks
# like. Stricter means a commit the exporter has already skipped, and will never
# record, stays in the backlog for good: a stale that no export can drain. So
# this reads the same union the exporter reads (oss-commit-sync lib.sh
# trailer_scan), and is deliberately no narrower.
#
# 0 yes, 1 no, 2 git failed. The tripling matters: collapsing a git failure into
# "no" would route the commit into a skip it was never entitled to.
originated_on_oss() {
  local block message
  # Git reading its own trailer block, which is the exporter's first source.
  # Both shapes it accepts and a hand-written regex does not are real: a space
  # before the colon, and a value folded onto the next line, which unfold joins
  # back up. Hex all through and no longer than 40, matching the exporter shape
  # test, so a folded value that joins into prose fails here as it does there.
  block="$(git log -1 --format='%(trailers:key=Oss-Commit,valueonly,unfold)' "$1")" || return 2
  if grep -qiE '^[0-9a-f]{7,40}[[:space:]]*$' <<<"${block}"; then
    return 0
  fi
  # Then the body, for a record a squash orphaned out of the block, with the
  # laxer key matching the exporter allows down there. A line whose successor is
  # indented was a folded value and records nothing, which is the rule that keeps
  # this scan agreeing with the unfolded block reading above.
  # (No apostrophes in the awk: it is a single-quoted shell string.)
  message="$(git log -1 --format='%B' "$1")" || return 2
  awk -v min=7 '
    function shaped(candidate) {
      return (candidate ~ /^[0-9a-f]+$/ && length(candidate) >= min && length(candidate) <= 40)
    }
    /^[ \t]/ && /[^ \t\r]/ { pending = ""; next }
    {
      if (pending != "" && shaped(pending)) { found = 1; exit }
      line = tolower($0)
      sub(/[ \t\r]+$/, "", line)
      pending = ""
      if (substr(line, 1, 10) != "oss-commit") next
      rest = substr(line, 11)
      sub(/^[ \t]+/, "", rest)
      if (substr(rest, 1, 1) != ":") next
      rest = substr(rest, 2)
      sub(/^[ \t]+/, "", rest)
      pending = rest
    }
    END {
      if (!found && pending != "" && shaped(pending)) found = 1
      exit(found ? 0 : 1)
    }
  ' <<<"${message}"
}

# The exporter refuses merges outright rather than skipping them, so one in the
# backlog is a hard stall that never drains. 0 yes, 1 no, 2 git failed.
is_merge() {
  local parents
  parents="$(git rev-list --parents --no-walk "$1")" || return 2
  [ "$(wc -w <<<"${parents}")" -gt 2 ]
}

# Whole hours the given commit has been waiting. Clock skew must not produce a
# negative age that compares below every threshold.
age_hours_of() {
  local epoch now
  epoch="$(git log -1 --format='%ct' "$1")" || return 1
  now="$(date -u +%s)"
  if [ "${epoch}" -gt "${now}" ]; then
    echo 0
  else
    echo $(((now - epoch) / 3600))
  fi
}

# The newest commit the export actually owed a record for, walking back from the
# given tip. Not the branch tip: most commits on the monorepo branch never touch
# the subtree, so a healthy mirror sits at a tip nobody ever exported. Not an
# imported commit either, which the export skips by design without recording it.
# Asking about either turns "the export may be dead" into a line that prints on
# every scheduled run, which is how a real signal gets trained out of a reader.
#
# 0 with the sha, 1 when the window holds nothing the export owed, 2 git failed.
# Captured rather than piped, because a `while read < <(git ...)` reports the
# loop's status and a git failure would arrive as an empty walk.
newest_owed_record() {
  local list sha rc
  list="$(git rev-list --first-parent --max-count="$((10#$SCAN_LIMIT))" "$1" -- "${SUBTREE_PREFIX}")" ||
    return 2
  [ -n "${list}" ] || return 1
  while IFS= read -r sha; do
    [ -n "${sha}" ] || continue
    rc=0
    originated_on_oss "${sha}" || rc=$?
    # Anything but a confident "this came from OSS" counts as owed, including a
    # git failure: the loud direction here is a warning, not a false all-clear.
    if [ "${rc}" -ne 0 ]; then
      printf '%s\n' "${sha}"
      return 0
    fi
  done <<<"${list}"
  return 1
}

# Prefix match, because a trailer may carry an abbreviated sha. Anchored at the
# start so a short value can only match the commit it abbreviates.
is_recorded() {
  local value
  for value in "${recorded[@]}"; do
    [[ "$1" == "$value"* ]] && return 0
  done
  return 1
}

main() {
  emit_defaults

  local missing=() name
  for name in SUBTREE_PREFIX OSS_REMOTE OSS_REPO BRANCH; do
    [ -n "${!name}" ] || missing+=("${name}")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    degrade "missing required input(s): ${missing[*]}"
  fi

  validate_numeric MAX_AGE_HOURS "${MAX_AGE_HOURS}" || degrade "invalid MAX_AGE_HOURS input"
  validate_numeric SCAN_LIMIT "${SCAN_LIMIT}" || degrade "invalid SCAN_LIMIT input"

  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || degrade "not inside a git repository"
  cd "${toplevel}" || degrade "could not enter ${toplevel}"

  # A shallow clone would put the frontier at the bottom of the clone, which reads
  # as "in sync".
  local shallow
  shallow="$(git rev-parse --is-shallow-repository 2>/dev/null)" || degrade "could not query the checkout depth"
  if [ "${shallow}" = "true" ]; then
    degrade "the checkout is shallow; this check needs fetch-depth: 0 to walk subtree history"
  fi

  git fetch --no-tags --quiet "${OSS_REMOTE}" "+refs/heads/${BRANCH}:${FETCH_REF}" 2>/dev/null ||
    degrade "could not fetch ${BRANCH} from the OSS remote (missing branch, bad token, or network)"

  local oss_tip
  oss_tip="$(git rev-parse --verify --quiet "${FETCH_REF}^{commit}")" ||
    degrade "fetched ${BRANCH} but could not resolve it to a commit"
  emit oss-tip "${oss_tip}"

  local monorepo_tip
  # Fully qualified: git resolves a bare name against refs/tags first, and these
  # branches are named v0.37 while the release tags are named v0.37.1.
  monorepo_tip="$(git rev-parse --verify --quiet "refs/heads/${BRANCH}^{commit}" ||
    git rev-parse --verify --quiet "refs/remotes/origin/${BRANCH}^{commit}")" ||
    degrade "no local ${BRANCH} to compare against"

  # `mapfile < <(git ...)` reports mapfile's status, never git's, so a git failure
  # would arrive as an empty list and read as a clean mirror.
  local recorded_raw rc=0
  recorded_raw="$(read_recorded_anchors)" || rc=$?
  # 1 is a real answer (no records) and handled below; 2 means git broke.
  if [ "$rc" -eq 2 ]; then
    degrade "could not read Monorepo-Commit records from the OSS branch"
  fi
  local recorded=()
  # `[ test ] && cmd` as a bare statement returns 1 when the test is false, which
  # under errexit ends the script.
  if [ -n "${recorded_raw}" ]; then
    mapfile -t recorded <<<"${recorded_raw}"
  fi

  # The direct answer to "is the mirror carrying what we have", and the only one
  # immune to the exporter's skip rules: a commit that originated on OSS or
  # applies as a no-op never gets a record, so the walk alone would count it as
  # backlog forever.
  local oss_tree mono_tree excludes=()
  build_excludes
  oss_tree="$(git rev-parse --verify --quiet "${FETCH_REF}^{tree}")" ||
    degrade "could not read the OSS branch tree"
  mono_tree="$(git rev-parse --verify --quiet "${monorepo_tip}:${SUBTREE_PREFIX}")" ||
    degrade "no ${SUBTREE_PREFIX} at ${BRANCH}; wrong prefix or wrong branch"
  # 0 agree, 1 differ, anything else git failed. Not `=` on the two tree shas:
  # with any exclude-paths configured they never match, and the short-circuit
  # this guards is the only reading immune to the exporter skip rules.
  rc=0
  git diff --quiet "${oss_tree}" "${mono_tree}" -- . ${excludes[@]+"${excludes[@]}"} || rc=$?
  if [ "${rc}" -gt 1 ]; then
    degrade "could not compare the mirror tree with ${SUBTREE_PREFIX} at ${BRANCH}"
  fi
  if [ "${rc}" -eq 0 ]; then
    summarize "In sync. The mirror carries the \`${SUBTREE_PREFIX}\` content of \`${monorepo_tip:0:12}\`."
    # Equal trees mean the mirror holds our code, which is the question asked, so
    # this is not staleness. But a tip with no record means the export did not
    # put it there: the content matched for another reason, a commit and its
    # revert both unexported being the ordinary one. Say so, because it is the
    # single case where a dead export produces no other signal.
    #
    # And frontier follows the same commit: naming one the export never owed a
    # record for would report the absence of a record as the newest record there
    # is. Empty when we genuinely did not find one.
    local owed owed_rc=0
    owed="$(newest_owed_record "${monorepo_tip}")" || owed_rc=$?
    if [ "${owed_rc}" -eq 2 ]; then
      # Not a warning-and-carry-on: the trees agreeing is only half the answer,
      # and returning with degraded false here would hand a caller a clean bill
      # of health for a question we did not manage to ask.
      degrade "the trees agree, but ${SUBTREE_PREFIX} history on ${BRANCH} could not be walked to check the export still runs"
    elif [ "${owed_rc}" -eq 0 ]; then
      if is_recorded "${owed}"; then
        emit frontier "${owed}"
      else
        # On its own output, because this is the one finding with nothing else to
        # carry it: the content is current, so stale stays false by definition,
        # and a warning in the log of a scheduled run is the same invisibility
        # the whole action was written to end.
        emit export-unconfirmed true
        echo "::warning::${BRANCH} matches the mirror by content, but no export recorded ${owed}; check that the export is still running"
        summarize "No export recorded \`${owed:0:12}\`, the newest commit it owed a record for, so the trees agree for some other reason. Worth confirming the export still runs on this branch."
      fi
    fi
    return 0
  fi

  if [ "${#recorded[@]}" -eq 0 ]; then
    degrade "no Monorepo-Commit record within the last ${SCAN_LIMIT} commits of OSS ${BRANCH}; cannot locate a frontier"
  fi

  local subtree_raw
  rc=0
  subtree_raw="$(git rev-list --first-parent --max-count="$((10#$SCAN_LIMIT))" "${monorepo_tip}" -- "${SUBTREE_PREFIX}")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    degrade "could not walk ${SUBTREE_PREFIX} history on ${BRANCH}"
  fi
  local subtree_commits=()
  if [ -n "${subtree_raw}" ]; then
    mapfile -t subtree_commits <<<"${subtree_raw}"
  fi

  if [ "${#subtree_commits[@]}" -eq 0 ]; then
    degrade "no commits touch ${SUBTREE_PREFIX} on ${BRANCH}; wrong prefix or wrong branch"
  fi

  local backlog=0 frontier="" oldest_unmirrored="" merge_blocker="" sha rc
  for sha in "${subtree_commits[@]}"; do
    if is_recorded "${sha}"; then
      frontier="${sha}"
      break
    fi
    # Every predicate here can only ever REMOVE a commit from the backlog, so a
    # git failure in one must not be allowed to look like a confident "skip it".
    # Both fall through to counting the commit, which is the loud direction.
    rc=0
    is_merge "${sha}" || rc=$?
    if [ "${rc}" -eq 2 ]; then
      echo "::warning::could not read the parents of ${sha}; counting it as backlog"
    elif [ "${rc}" -eq 0 ]; then
      merge_blocker="${sha}"
    else
      # An imported community contribution never gets a record, so without this
      # it sits in the backlog forever and alerts on a line that is current.
      rc=0
      originated_on_oss "${sha}" || rc=$?
      if [ "${rc}" -eq 0 ]; then
        continue
      elif [ "${rc}" -eq 2 ]; then
        echo "::warning::could not read the message of ${sha}; counting it as backlog"
      fi
    fi
    oldest_unmirrored="${sha}"
    backlog=$((backlog + 1))
  done

  emit backlog-count "${backlog}"
  emit frontier "${frontier}"

  # Said before either exit below, because the deepest backlog is both the one
  # that degrades and the one most likely to be stuck behind a merge.
  if [ -n "${merge_blocker}" ]; then
    echo "::warning::${merge_blocker} is a merge commit, which the export refuses; ${BRANCH} cannot drain until that history is linear"
    summarize "The backlog contains a merge commit (\`${merge_blocker:0:12}\`). The export refuses merges, so this will not clear on its own."
  fi

  # Either the mirror is further behind than the window or the records belong to
  # another branch. Both need a human, and neither is "in sync". Only claim
  # staleness when something is actually waiting, so the flag never contradicts a
  # backlog of zero.
  #
  # No age gate here, unlike every other route to stale: the threshold buys a
  # commit time to be exported normally, and a backlog deeper than the whole scan
  # window has already spent it, whatever the newest commit in it is dated. Said
  # in the stale output description too, because a caller routing stale and
  # degraded to different places is reading that and not this.
  if [ -z "${frontier}" ]; then
    if [ "${backlog}" -gt 0 ]; then
      emit stale true
    fi
    emit oldest-unmirrored "${oldest_unmirrored}"
    if [ -n "${oldest_unmirrored}" ]; then
      emit oldest-unmirrored-age-hours "$(age_hours_of "${oldest_unmirrored}" || echo 0)"
    fi
    degrade "no frontier within the last ${SCAN_LIMIT} subtree commits on ${BRANCH}: the mirror is at least ${backlog} commits behind, or its records do not match this branch"
  fi

  if [ "${backlog}" -eq 0 ]; then
    summarize "In sync. The mirror carries every \`${SUBTREE_PREFIX}\` commit on \`${BRANCH}\` (frontier \`${frontier:0:12}\`)."
    return 0
  fi

  # The oldest thing still waiting, not the newest: a commit that landed a minute
  # ago has not had time to mirror and must not alert.
  local age_hours
  age_hours="$(age_hours_of "${oldest_unmirrored}")" ||
    degrade "could not read the commit date of ${oldest_unmirrored}"

  emit oldest-unmirrored "${oldest_unmirrored}"
  emit oldest-unmirrored-age-hours "${age_hours}"

  if [ "${age_hours}" -ge "$((10#$MAX_AGE_HOURS))" ]; then
    emit stale true
    echo "::warning::${OSS_REPO} ${BRANCH} is ${backlog} commit(s) behind ${SUBTREE_PREFIX}; the oldest has been waiting ${age_hours}h"
    summarize "**Stale.** \`${backlog}\` commit(s) in \`${SUBTREE_PREFIX}\` are missing from the mirror. The oldest (\`${oldest_unmirrored:0:12}\`) has been waiting **${age_hours}h**, past the ${MAX_AGE_HOURS}h threshold."
  else
    summarize "Catching up. \`${backlog}\` commit(s) not yet mirrored, oldest waiting ${age_hours}h, within the ${MAX_AGE_HOURS}h threshold."
  fi
}

# Only auto-run when executed directly; sourcing (e.g. from bats) must not.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

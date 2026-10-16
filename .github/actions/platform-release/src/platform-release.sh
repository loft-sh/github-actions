#!/usr/bin/env bash
# Single release dispatcher for vCluster Platform.
#
# One entry point for cutting a Platform release on any supported line. The
# version string decides the routing; nobody has to remember which branch a
# given version is cut from.
#
# The GitHub Release is treated as a pipeline *output*, not a trigger: this
# script only creates the tag and dispatches the line's own release.yaml via
# `gh workflow run --ref <tag>` (which runs the tagged commit's version of the
# workflow). The dispatched builder creates the release at the end of a green
# build, so nothing triggers on `release:created` and no build can re-trigger
# itself.
#
# Platform is always a single repo, so unlike the vcluster-release sibling this
# carries no era classification, no cross-repo tagging and no dependency-bump
# wait. What remains is the repo-agnostic core: validate -> route -> guard ->
# tag the target branch head -> dispatch release.yaml at the tag.
#
# The prerelease suffix decides which branch a version may be cut from
# (fail-closed - an unroutable suffix like -devpod.alpha is rejected, never
# guessed):
#   -alpha / -beta         -> main only, and refused once release-X.Y exists
#   -rc                    -> release-X.Y once that branch exists (an explicit
#                             main is refused there), otherwise main
#   stable (vX.Y.Z)        -> the release-X.Y branch only
#   -next / -next.internal -> a short-lived feature branch (source-branch input
#                             required)
#
# dry_run (default true) performs the read-only checks (branch existence,
# double-cut guard) so the printed routing decision is validated, but prints the
# mutating tag/dispatch calls instead of firing them.
set -euo pipefail

# Sourced from PLATFORM_-prefixed names, not the bare ones. A composite action's
# steps inherit the caller's workflow- and job-level `env:`, and `REPO` is a
# common enough workflow variable that a caller setting it would silently
# redirect the whole cut: resolve_head, check_release_state, create_tag and
# dispatch all follow REPO, so even the dry-run output stays internally
# consistent while naming the wrong repository. The prefix makes an accidental
# collision implausible while keeping one override seam for the bats suite,
# which drives alternative spellings through these same variables.
REPO="${PLATFORM_REPO:-loft-sh/loft-enterprise}"
WORKFLOW="${PLATFORM_WORKFLOW:-release.yaml}"
# Platform release branches are named `release-4.11`, not vcluster's `v0.37`.
# Kept as a printf format over (major, minor) so the naming convention is stated
# once and the bats suite can drive an alternative spelling.
LINE_BRANCH_FORMAT="${PLATFORM_LINE_BRANCH_FORMAT:-release-%s.%s}"
# Matches LINE_BRANCH_FORMAT. Used by is_feature_branch to tell a release-line
# branch from a short-lived feature branch.
LINE_BRANCH_PATTERN="${PLATFORM_LINE_BRANCH_PATTERN:-^release-[0-9]+\.[0-9]+$}"
DEFAULT_BRANCH="${PLATFORM_DEFAULT_BRANCH:-main}"
# The human who invoked cut-release. Forwarded to release.yaml
# (-f triggered_by=...) so the Slack banner attributes the person, not the bot
# PAT that dispatches the build. action.yml wires this from github.actor, which
# is never empty, so in the composite it is always passed; the empty case is for
# a direct script invocation. `gh workflow run` rejects undeclared inputs, so a
# release-X.Y line whose release.yaml has no `triggered_by` input fails at the
# dispatch, which require_dispatchable checks for before anything is tagged.
TRIGGERED_BY="${TRIGGERED_BY:-}"
# Set by require_dispatchable when the line's release.yaml declares a
# `source_branch` input. The cut then passes the branch it tagged, so the Slack
# banner names it instead of inferring it from git history, which cannot tell
# which branch a tag came from when it sits on several. Optional rather than
# required like triggered_by: lines cut before the input existed keep
# dispatching, and their banner falls back to the inference.
FORWARD_SOURCE_BRANCH=""
# Set by cut_release before the preflight when it cannot name the branch the
# tag was cut from. The preflight then leaves source_branch out unless the line
# requires it with no default, so the banner falls back to the inference.
SOURCE_BRANCH_UNKNOWN=""
# How long dispatch waits for the run it started to be listed, before the cut
# exits and a following cut could miss it. Overridable so the bats suite does
# not sleep.
DISPATCH_VISIBLE_ATTEMPTS="${PLATFORM_DISPATCH_VISIBLE_ATTEMPTS:-12}"
DISPATCH_VISIBLE_SLEEP_SECONDS="${PLATFORM_DISPATCH_VISIBLE_SLEEP_SECONDS:-5}"

# Reaching across actions the way oss-mirror-staleness reaches into
# oss-commit-sync. A caller pinning platform-release/v1 checks out the whole
# repository at that tag, so the lib read here is the one this version was
# written against.
# shellcheck source=.github/actions/release-lib/lib.sh disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../release-lib/lib.sh"

# The README sections a refusal points at for what to do next. The steps depend
# on what the runs do next, so they live there rather than in the error. Linked
# at the ref the caller runs, so the steps match the code printing the error.
RECOVERY_REF="platform-release/v1"
if [[ "${GITHUB_ACTION_REPOSITORY:-}" == "loft-sh/github-actions" && "${GITHUB_ACTION_REF:-}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  RECOVERY_REF="$GITHUB_ACTION_REF"
fi
RECOVERY_DOC="https://github.com/loft-sh/github-actions/blob/${RECOVERY_REF}/.github/actions/platform-release/README.md"
PARTIAL_RECOVERY="${RECOVERY_DOC}#partial-failure-recovery"
DRAFT_RECOVERY="${RECOVERY_DOC}#draft-releases"
# How many passed commits a refusal names. The earlier attempts of other
# commits' re-runs are read only until this many commits with a newer pass are
# known, since an older pass could not make the list.
PASSES_NAMED=3

# capped <max> <item>... - the items joined with ", ", the ones past <max>
# counted instead, so a list in an error line cannot push what follows it past
# the annotation cutoff.
capped() {
  local max="$1" out="" item
  shift
  for item in "${@:1:max}"; do out+="${out:+, }${item}"; done
  (($# > max)) && out+=", and $(($# - max)) more"
  printf '%s' "$out"
}

# capped_text <text> - <text> flattened and cut at 300 characters, so a long gh
# diagnostic cannot push the rest of a refusal past the annotation cutoff.
capped_text() {
  local text
  text="$(flatten "$1")"
  ((${#text} > 300)) && text="${text:0:300}..."
  printf '%s' "$text"
}

# earlier_passed <repo> <run-id> <attempt> - whether an attempt of the run before
# <attempt> passed. Returns 0 when one did, even if another could not be read,
# 2 when none did but one could not be read or came back with no conclusion,
# and 1 when none did. On 2 the first cause is kept in READ_ERR, unless it
# already holds one.
earlier_passed() {
  local k prior err="" rc
  for ((k = 1; k < $3; k++)); do
    rc=0 prior=""
    api_read prior "repos/${1}/actions/runs/${2}/attempts/${k}" "attempt ${k} of run ${2} in ${1}" '.conclusion // "none"' || rc=$?
    if ((rc)); then
      err="${err:-$API_READ_ERR}"
    elif [[ "$prior" == "success" ]]; then
      return 0
    elif [[ -z "$prior" || "$prior" == "none" ]]; then
      # A finished attempt always has a conclusion, so this read is not an
      # answer, and taking it for a failure could let a second build through.
      err="${err:-attempt ${k} of run ${2} in ${1} came back with no conclusion}"
    fi
  done
  [[ -n "$err" ]] || return 1
  READ_ERR="${READ_ERR:-$err}"
  return 2
}

# scan_reruns <repo> <list-var> <max> - whether a run in the array named
# <list-var> passed in an attempt the run list does not show. Its lines are
# "<id> <sha> <before>", newest first, and attempts 1 to <before>-1 are read,
# skipping any commit already known to have passed. With <max> above 0, a run
# with <max> commits known to have passed after it is not read, and is counted
# in the caller's unscanned instead. Adds what it finds to check_release_state's
# passed, newest_pass and unread.
scan_reruns() {
  local repo="$1" max="$3" entry id run_sha before newer b pass
  # A misnamed list would expand to nothing and switch the guard off.
  if ! declare -p "$2" &>/dev/null; then
    echo "::error::scan_reruns: no list named '$2'" >&2
    exit 1
  fi
  local -n __sr_list="$2"
  for entry in "${__sr_list[@]}"; do
    read -r id run_sha before <<<"$entry"
    [[ -z "${newest_pass[$run_sha]+x}" ]] || continue
    if ((max)); then
      newer=0
      for b in "${!newest_pass[@]}"; do ((newest_pass[$b] > id)) && newer=$((newer + 1)); done
      if ((newer >= max)); then
        unscanned=$((unscanned + 1))
        continue
      fi
    fi
    pass=0
    earlier_passed "$repo" "$id" "$before" || pass=$?
    ((pass == 0)) && passed+=("${id} ${run_sha}") newest_pass[$run_sha]=$id
    ((pass == 2)) && unread+=("$id")
  done
  return 0
}

# check_release_state <repo> <tag> - how far an earlier cut of this version got,
# and whether this one may carry on from there. Sets EXISTING_TAG_SHA to the
# tagged commit when the tag already exists and the cut should resume at the
# dispatch, or to empty when nothing exists yet and the cut starts from the tag.
#
# Refused:
#   - a published release: the version shipped, and releases are cut once
#   - a draft release. goreleaser drafts the release before uploading and
#     publishes it last, and deleting a tag turns its published release back
#     into a draft. Promotion cannot finish a draft, and building again beside
#     one leaves two, so a human settles it first
#   - a build still running under the tag name, whether or not the tag still
#     exists: dispatching again would race it
#   - a build that passed at the tag, in any attempt: it should have
#     published, so something needs a human, and another build could publish
#     the version twice
# A refusal says what the cut saw and links the README for what to do next. It
# gives no advice of its own: whether waiting, cancelling, deleting or
# publishing is safe depends on what a running build does next, and on whether
# a release was pulled on purpose, and the cut can see neither.
#
# Resumed: a tag with no build at all, or only failed or cancelled builds. The
# tag stays where the first cut put it. Moving it would change what ships under
# a version that already has builds recorded against it.
#
# The action never deletes a tag. A failed dispatch leaves the tag in place and
# the re-run lands here.
check_release_state() {
  local repo="$1" tag="$2" listing err
  # Both spellings, like tag_runs: a run dispatched at the full ref may be
  # listed under it. gh run list stops at 20 runs unless told otherwise.
  local inspect="Inspect: gh run list --repo ${repo} --workflow ${WORKFLOW} --limit 1000 --branch ${tag}, and again with --branch refs/tags/${tag}"
  EXISTING_TAG_SHA=""
  # The runs are read before the releases. A build that publishes between the
  # two reads then shows up as a published release, which is final, rather than
  # as a passed build beside nothing but its own draft.
  #
  # They are also read before the tag probe, because a missing tag does not
  # prove nothing is building: the tag can be deleted under a running build, and
  # re-creating it at the branch head would start a second build of the version
  # from another commit. Only runs that have not completed block. Run records
  # outlive the tag, so blocking on any run ever would stop the delete-and-re-cut
  # path for good.
  #
  # A failed listing is reported after the releases are read, so a version that
  # already shipped still gets the double-cut guard rather than an API error.
  local runs runs_failed=0
  tag_runs runs "$repo" "$WORKFLOW" "$tag" || runs_failed=1
  # One listing answers for published and draft releases alike. The singular
  # releases/tags/ endpoint cannot replace it, since it never returns a draft.
  # Drafts only appear to a token that can push, which require_push_access has
  # checked. A failed listing aborts rather than reading as "not released".
  if ! run_captured listing err gh api --paginate "repos/${repo}/releases?per_page=100" --jq '.[] | "\(.draft) \(.tag_name) \(.id) \(.published_at // "none")"'; then
    echo "::error::could not list releases in ${repo} to check for ${tag}. Not treating as absent. gh said: $(gh_reason "$err")" >&2
    exit 1
  fi
  # GitHub allows several drafts for one tag, and `gh release delete` cannot
  # pick between them, so drafts are named by id. A publish time proves a draft
  # shipped once. Published drafts are listed first, so the ones that must be
  # kept are named before any are counted away. A release can come back twice
  # when the list shifts between pages, and change between the two reads. Each
  # id is counted once, as its most final copy: published, then a draft that was
  # published, then one that never was.
  local is_draft rel_tag rel_id rel_published rank rel_order=()
  local -A rel_rank=() rel_time=()
  while read -r is_draft rel_tag rel_id rel_published; do
    [[ "$rel_tag" == "$tag" ]] || continue
    rank=0
    [[ "$rel_published" != "none" ]] && rank=1
    [[ "$is_draft" != "true" ]] && rank=2
    [[ -n "${rel_rank[$rel_id]+x}" ]] || rel_order+=("$rel_id")
    if [[ -z "${rel_rank[$rel_id]+x}" ]] || ((rank > rel_rank[$rel_id])); then
      rel_rank[$rel_id]=$rank rel_time[$rel_id]="$rel_published"
    fi
  done <<<"$listing"
  local published=0 shipped=0 named=() unshipped=()
  for rel_id in "${rel_order[@]}"; do
    case "${rel_rank[$rel_id]}" in
      2) published=1 ;;
      1) shipped=$((shipped + 1)) named+=("${rel_id} (published ${rel_time[$rel_id]})") ;;
      *) unshipped+=("${rel_id} (no publish time)") ;;
    esac
  done
  named+=("${unshipped[@]}")
  local drafts=${#named[@]} runs_note=""
  # Without the runs, a release or draft still refuses, and says so with what
  # it cannot rule out. Anything else cannot be decided.
  if ((runs_failed)); then
    if ((!published && !drafts)); then
      echo "::error::could not list ${WORKFLOW} runs at ${tag} in ${repo}, so the cut cannot tell whether a build is already running. Nothing was dispatched. gh said: $(gh_reason "$TAG_RUNS_ERR")" >&2
      exit 1
    fi
    runs="" runs_note=" The ${WORKFLOW} runs could not be listed, so a running or passed build is not ruled out. gh said: $(capped_text "$(gh_reason "$TAG_RUNS_ERR")")"
  fi
  # The list shows only a run's latest attempt, so a re-run whose latest
  # attempt did not pass can hide an earlier one that did, and published. A
  # finished run always has a conclusion, so one listed without it is not an
  # answer either, and its latest attempt is read too rather than taken for a
  # failure. Newest first, for the cap on live runs and the early stop on
  # re-runs below.
  local id run_sha status conclusion attempt before live=() passed=() rerun=()
  while read -r id run_sha status conclusion attempt; do
    [[ -n "$id" ]] || continue
    [[ "$status" == "completed" ]] || live=("${id} (${status})" "${live[@]}")
    if [[ "$status" == "completed" && "$conclusion" == "success" ]]; then
      passed+=("${id} ${run_sha}")
      continue
    fi
    before=$attempt
    [[ "$status" == "completed" && "$conclusion" == "none" ]] && before=$((attempt + 1))
    if ((before > 1)); then
      rerun=("${id} ${run_sha} ${before}" "${rerun[@]}")
    fi
  done <<<"$runs"
  if ((published && !drafts && !${#live[@]})); then
    echo "::error::release ${tag} already exists in ${repo}. Refusing to re-cut (double-cut guard).${runs_note}" >&2
    exit 1
  fi
  # Past here a draft or a live run refuses the cut whatever else is read, so
  # a failed read is then reported among the facts rather than ending the cut
  # before it names them. Otherwise it ends the cut, as the refusal hangs on it.
  local refusing=0
  ((drafts || ${#live[@]})) && refusing=1
  local sha="" tagged=0 untagged=0 tag_note="" tag_reason="" rc=0
  resolve_tag sha "$repo" "$tag" || rc=$?
  case "$rc" in
    0) tagged=1 ;;
    1) untagged=1 ;;
    *)
      if ((!refusing)); then
        if ((rc == 2)); then
          echo "::error::${TAG_ERR}" >&2
        else
          echo "::error::${TAG_ERR}. Nothing was dispatched." >&2
        fi
        exit 1
      fi
      sha=""
      if ((rc == 2)); then
        tag_note="tag ${tag} could not be read." tag_reason="$(capped_text "$TAG_ERR")"
      else
        tag_note="${TAG_ERR}."
      fi
      ;;
  esac
  # Earlier attempts cost a call each, so a commit already known to have passed
  # is not read again. The tag's re-runs are read first, since a pass there
  # refuses the cut. The others are read only once it refuses, for the passed
  # commits it reports, and only until PASSES_NAMED commits with newer passes
  # are known.
  local entry unread=() unscanned=0 b passed_at_tag=0 tag_reruns=() other_reruns=()
  local -A newest_pass=()
  for entry in "${passed[@]}"; do
    read -r id run_sha <<<"$entry"
    ((id > ${newest_pass[$run_sha]:-0})) && newest_pass[$run_sha]=$id
  done
  for entry in "${rerun[@]}"; do
    read -r id run_sha _ <<<"$entry"
    if ((tagged)) && [[ "$run_sha" == "$sha" ]]; then
      tag_reruns+=("$entry")
    else
      other_reruns+=("$entry")
    fi
  done
  READ_ERR=""
  scan_reruns "$repo" tag_reruns 0
  ((tagged)) && [[ -n "${newest_pass[$sha]+x}" ]] && passed_at_tag=1 refusing=1
  if ((${#unread[@]} && !refusing)); then
    echo "::error::could not read every attempt of ${WORKFLOW} run $(capped 5 "${unread[@]}") for ${tag} in ${repo}, so the cut cannot tell whether it passed and published. Nothing was dispatched. Cause: $(capped_text "$READ_ERR"). Steps: ${PARTIAL_RECOVERY} ${inspect}" >&2
    exit 1
  fi
  ((refusing)) && scan_reruns "$repo" other_reruns "$PASSES_NAMED"
  # Newest run first, so the cap keeps the passes most likely to be the version
  # as it went out, and counts away the ones from before a re-cut.
  local built=()
  local -A seen=()
  while read -r _ b; do
    [[ -n "$b" && -z "${seen[$b]+x}" ]] || continue
    seen[$b]=1
    built+=("$b")
  done < <(printf '%s\n' "${passed[@]}" | sort -rn -k1,1)
  local reasons=()
  ((published)) && reasons+=("release ${tag} already exists")
  if ((drafts == 1)); then
    reasons+=("a draft release for ${tag} exists")
  elif ((drafts > 1)); then
    reasons+=("${drafts} draft releases for ${tag} exist")
  fi
  if ((${#live[@]} == 1)); then
    reasons+=("a ${WORKFLOW} run for ${tag} is still going")
  elif ((${#live[@]} > 1)); then
    reasons+=("${#live[@]} ${WORKFLOW} runs for ${tag} are still going")
  fi
  ((passed_at_tag && !published)) && reasons+=("a ${WORKFLOW} run at tag ${tag} already passed, but there is no published release")
  if ((!${#reasons[@]})); then
    EXISTING_TAG_SHA="$sha"
    return 0
  fi
  local stopped="Nothing was dispatched." steps="Steps: ${PARTIAL_RECOVERY}"
  ((untagged)) && stopped="Nothing was tagged."
  ((drafts)) && steps="Read the steps before deleting or publishing a draft or cancelling a run: ${DRAFT_RECOVERY}"
  local why
  printf -v why '%s; ' "${reasons[@]}"
  why="${why%; }"
  echo "::error::refusing to cut ${tag} in ${repo}: ${why}. ${stopped} ${steps}" >&2
  # Each list is capped, so this line always fits in one annotation.
  local facts="tag ${tag} does not exist."
  ((tagged)) && facts="tag ${tag} points at ${sha}."
  [[ -n "$tag_note" ]] && facts="$tag_note"
  if ((drafts)); then
    facts+=" Drafts by id: $(capped 5 "${named[@]}")"
    ((shipped > 5)) && facts+=", $((shipped - 5)) of them published"
    facts+="."
  fi
  ((${#live[@]})) && facts+=" Still going: runs $(capped 5 "${live[@]}")."
  ((${#built[@]})) && facts+=" Passed ${WORKFLOW} runs built $(capped "$PASSES_NAMED" "${built[@]}")."
  if ((unscanned == 1)); then
    facts+=" 1 older run was not checked for a pass the run list does not show."
  elif ((unscanned > 1)); then
    facts+=" ${unscanned} older runs were not checked for a pass the run list does not show."
  fi
  ((${#unread[@]})) && facts+=" Not every attempt could be read for runs $(capped 5 "${unread[@]}")."
  facts+="$runs_note"
  echo "::error::What the cut saw for ${tag} in ${repo}: ${facts} ${inspect}" >&2
  # Kept off the facts line, which the capped lists already fill.
  local failed=()
  [[ -n "$tag_reason" ]] && failed+=("$tag_reason")
  ((${#unread[@]})) && failed+=("$(capped_text "$READ_ERR")")
  if ((${#failed[@]})); then
    local said
    printf -v said '%s; ' "${failed[@]}"
    echo "::error::Reads that failed while gathering those facts: ${said%; }" >&2
  fi
  exit 1
}

# require_push_access <repo> - hard error if the token cannot see <repo>, or can
# read it but not push to it. GitHub answers 404 for a private repo the token
# has no access to, and every probe after this one reads a 404 as "absent", so a
# missing grant would route the cut as if no line branch existed and then blame
# a missing branch. A read-only token could not create the tag anyway, but it
# also sees no draft releases, so the double-cut guard would read "no draft"
# when it could not look, and a dry-run would print a cut it had not really
# checked. GitHub reports no permissions for a GitHub App token, so their
# absence only warns.
require_push_access() {
  local repo="$1" push
  if ! api_get push "repos/${repo}" "repository ${repo}" '.permissions.push | if . == null then "unknown" else tostring end'; then
    echo "::error::the token cannot see ${repo} (GitHub answers 404 for a private repo the token has no access to). Check that github-token has repo and workflow scope on ${repo}. Nothing was tagged." >&2
    exit 1
  fi
  case "$push" in
    true) ;;
    false)
      echo "::error::the token can read ${repo} but cannot push to it, so it can neither see draft releases for the double-cut guard nor create the tag. Check that github-token has repo and workflow scope on ${repo}. Nothing was tagged." >&2
      exit 1 ;;
    *)
      echo "::warning::GitHub reported no permissions for the token on ${repo} (a GitHub App token gets none), so the double-cut guard cannot confirm it sees draft releases." >&2 ;;
  esac
}

# create_tag <repo> <branch> <tag> <sha> - tag that exact commit. release.yaml
# triggers on workflow_dispatch, not tag push, so this does not start the build.
# The repo's other tag-push workflows (code-freeze, golangci-lint) do fire.
create_tag() {
  local repo="$1" branch="$2" tag="$3" sha="$4"
  if [[ "${DRY_RUN:-true}" == "true" ]]; then
    echo "[dry-run] gh api -X POST repos/${repo}/git/refs -f ref=refs/tags/${tag} -f sha=${sha}"
    return 0
  fi
  # Checked for the same reason the ref read above is: under set -e a bare call
  # aborts with gh's raw one-liner and no ::error:: annotation, which is the one
  # failure in this script that would leave the operator without guidance. The
  # live causes are a PAT without write on a protected ref, and a concurrent cut
  # that created the tag in the window since check_release_state.
  if ! gh api -X POST "repos/${repo}/git/refs" -f ref="refs/tags/${tag}" -f sha="${sha}" >/dev/null; then
    echo "::error::failed to create tag ${tag} in ${repo} at ${sha}. Either the token lacks write access on refs in ${repo} (a protected-tag rule will also reject it), or a concurrent cut created ${tag} after the double-cut guard ran, in which case re-running the cut resumes from that tag. Nothing was dispatched. See the gh error above." >&2
    exit 1
  fi
  echo "created tag ${tag} in ${repo} at ${branch} (${sha})"
}

# dispatch <repo> <tag> <sha> [extra gh flags...] - run that ref's release.yaml.
# --ref executes the tagged commit's version of the workflow, so each line
# builds with its own glue. It is the full ref, since a branch that shares the
# tag's name would otherwise be what GitHub runs. <sha> is the tagged commit,
# which the wait below matches runs against.
dispatch() {
  local repo="$1" tag="$2" sha="$3"
  shift 3
  local extra=("$@")
  if [[ "${DRY_RUN:-true}" == "true" ]]; then
    echo "[dry-run] gh workflow run ${WORKFLOW} --repo ${repo} --ref refs/tags/${tag} ${extra[*]}"
    return 0
  fi
  # Counted first, so the wait below recognises the new run even on a resume,
  # where failed runs of the same commit are already listed.
  local runs before
  if ! tag_runs runs "$repo" "$WORKFLOW" "$tag"; then
    echo "::error::could not list ${WORKFLOW} runs at ${tag} in ${repo} before dispatching. Tag ${tag} stays in place: re-run the cut with the same version and it resumes at the dispatch. gh said: $(gh_reason "$TAG_RUNS_ERR")" >&2
    exit 1
  fi
  before="$(count_runs_at "$runs" "$sha")"
  # The tag is never deleted here. A non-zero exit does not prove GitHub
  # rejected the dispatch (the response can be lost after the run was queued),
  # and deleting the tag under a queued build would break it. The re-run reads
  # the run list instead: it resumes when nothing was queued and refuses when
  # a build is running.
  if ! gh workflow run "${WORKFLOW}" --repo "${repo}" --ref "refs/tags/${tag}" "${extra[@]}"; then
    echo "::error::failed to dispatch ${WORKFLOW} in ${repo} at ${tag}. Tag ${tag} stays in place: fix the cause and re-run the cut with the same version, and it resumes at the dispatch. Check that ${WORKFLOW} at ${tag} has a workflow_dispatch trigger and declares every input passed above. See the gh error above." >&2
    exit 1
  fi
  echo "dispatched ${WORKFLOW} in ${repo} at ${tag}"
  # `gh workflow run` returns before the run is listed. The caller's concurrency
  # group ends when this cut exits, so a cut started in that window would see
  # the tag with no running build and dispatch a second one. Waiting until the
  # run shows up in the same listing check_release_state reads closes the gap.
  # Failed reads just keep waiting, and running out of time only warns: the
  # build is already queued, and failing the cut now would be worse than the
  # window it guards.
  local i
  for ((i = 1; i <= DISPATCH_VISIBLE_ATTEMPTS; i++)); do
    if tag_runs runs "$repo" "$WORKFLOW" "$tag" && (( $(count_runs_at "$runs" "$sha") > before )); then
      return 0
    fi
    ((i < DISPATCH_VISIBLE_ATTEMPTS)) && sleep "${DISPATCH_VISIBLE_SLEEP_SECONDS}"
  done
  echo "::warning::${WORKFLOW} was dispatched in ${repo} at ${tag}, but the run was not listed within $((DISPATCH_VISIBLE_ATTEMPTS * DISPATCH_VISIBLE_SLEEP_SECONDS))s. A cut of ${tag} started right now could dispatch it a second time."
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

# cut_release <version> <target-branch> - the whole single-repo cut.
cut_release() {
  local version="$1" target="$2"
  echo "Routing ${version} -> ${REPO} (target ${target})"
  # State first: a cut that only has to resume, or is refused as already
  # released, does not need the branch head, and a -next branch is often gone
  # by then.
  check_release_state "$REPO" "$version"
  local sha label
  SOURCE_BRANCH_UNKNOWN=""
  if [[ -n "$EXISTING_TAG_SHA" ]]; then
    # A resumed cut builds the commit the tag already points at, so that is the
    # release.yaml the preflight has to read, whatever the branch head is now.
    require_tag_on_target "$REPO" "$target" "$version" "$EXISTING_TAG_SHA"
    # A resumed rc on its line may have been tagged on main before the line was
    # branched from a newer main, and the cut cannot tell.
    if [[ "$target" != "$DEFAULT_BRANCH" && "$(classify_suffix "$version")" == rc ]]; then
      SOURCE_BRANCH_UNKNOWN=1
    fi
    sha="$EXISTING_TAG_SHA" label="$version"
  else
    # Resolved once and used for both the preflight read and the tag, since the
    # branch is a moving ref. Read in dry-run too, so the preview names the
    # commit it would tag.
    sha="$(resolve_head "$REPO" "$target")" || exit 1
    label="$target"
  fi
  # On a resume too: its build ships whatever commit the tag points at, and a
  # tag made by hand need not be the rc's.
  require_rc_commit "$REPO" "$version" "$sha" 0 "${EXISTING_TAG_SHA:+resume}"
  # Announced only once the rc check passed, so a refused resume does not log one.
  if [[ -n "$EXISTING_TAG_SHA" ]]; then
    echo "::notice::tag ${version} already exists at ${EXISTING_TAG_SHA} on ${target} with no release and no build running or passed; resuming at the dispatch without re-tagging."
  fi
  # Before create_tag, deliberately: every tag starts the repo's tag-push
  # workflows, so a cut that cannot build should stop before it makes one.
  require_dispatchable "$REPO" "$sha" "$WORKFLOW" "$version" "$label"
  require_workflow_active "$REPO" "$WORKFLOW"
  if [[ -z "$EXISTING_TAG_SHA" ]]; then
    create_tag "$REPO" "$target" "$version" "$sha"
  fi
  local dispatch_args=()
  [[ -n "${TRIGGERED_BY}" ]] && dispatch_args=(-f "triggered_by=${TRIGGERED_BY}")
  [[ -n "${FORWARD_SOURCE_BRANCH}" ]] && dispatch_args+=(-f "source_branch=${target}")
  dispatch "$REPO" "$version" "$sha" "${dispatch_args[@]}"
}

main() {
  # Flattened here, once, rather than in each message that quotes it back.
  local raw_version version line raw_dry_run
  # Checked rather than `${INPUT_VERSION:?}`: GitHub does not enforce
  # `required: true` on a composite action input, so a caller wiring version
  # from an optional workflow input or an empty step output reaches this - and
  # the `:?` abort prints a bare bash line with no ::error::, leaving the run
  # with nothing in its annotations panel. Every other input failure here
  # annotates.
  if [[ -z "${INPUT_VERSION:-}" ]]; then
    echo "::error::version is required: the release to cut, e.g. v4.11.3. Nothing was tagged." >&2
    exit 1
  fi
  raw_version="$(flatten "${INPUT_VERSION}")"
  # Canonicalize before ANY consumer sees it: the tag name, the double-cut probe
  # and every routing decision must all agree on one spelling. Echo the rewrite
  # so the run log shows exactly which tag is about to be created.
  version="$(normalize_version "$raw_version")"
  # Gate on the canonical value, before any branch is read or tag created. This
  # is the single validation point for every release line, so a line's own
  # release.yaml never sees a malformed version even though it carries no gate.
  validate_version "$version" || exit 1
  # Echoed only after the gate. raw_version was flattened where it was read, so
  # neither this notice nor validate_version's error can carry a forged second
  # workflow command.
  if [[ "$version" != "$raw_version" ]]; then
    echo "::notice::normalized version '${raw_version}' -> '${version}'"
  fi
  # Fail closed: only an explicit, unambiguous "false" cuts for real. Any other
  # value (empty, typo, "yes", "1", stray whitespace) stays in dry-run, so a
  # misconfigured caller can never accidentally fire a real cut. Case is folded
  # first: nobody types FALSE meaning "preview it", so honouring it beats a
  # no-op run the operator has to diagnose.
  # Flattened like the other two operator inputs: the unrecognized-value warning
  # below quotes it straight back into an annotation.
  raw_dry_run="$(flatten "${INPUT_DRY_RUN:-true}")"
  case "${raw_dry_run,,}" in
    false) DRY_RUN="false" ;;
    true)  DRY_RUN="true" ;;
    *)
      echo "::warning::unrecognized dry-run value '${raw_dry_run}'; defaulting to dry-run (no mutations). Pass exactly 'false' to cut for real." >&2
      DRY_RUN="true"
      ;;
  esac
  export DRY_RUN

  local suffix source_branch target
  suffix="$(classify_suffix "$version")" || exit 1
  source_branch="$(trim "$(flatten "${INPUT_SOURCE_BRANCH:-}")")"
  # Gated before anything reads it: the routing guards compare it as a string
  # and every consumer then puts it in a URL.
  if [[ -n "$source_branch" ]] && ! validate_branch "$source_branch"; then
    exit 1
  fi
  line="$(derive_line "$version")"
  echo "platform-release: version=${version} suffix=${suffix} source-branch=${source_branch:-<none>} line=${line} dry_run=${DRY_RUN}"
  # Checked before any API call, so a runner without the right yq fails fast.
  require_yq
  # Before any branch probe, since each of them reads a 404 as "absent".
  require_push_access "$REPO"

  # -next/-next.internal are cut from a short-lived feature branch, which cannot
  # be derived from the version - it has to be named. Everything else routes
  # through the suffix matrix.
  if [[ "$suffix" == "next" || "$suffix" == "next-internal" ]]; then
    if [[ -z "$source_branch" ]]; then
      echo "::error::${suffix} releases require the source-branch input (the short-lived feature branch to cut from)." >&2
      exit 1
    fi
    if ! is_feature_branch "$source_branch"; then
      echo "::error::${suffix} releases are cut from a short-lived feature branch, not '${source_branch}' (${DEFAULT_BRANCH} and release-X.Y branches are not allowed)." >&2
      exit 1
    fi
    target="$source_branch"
  else
    # Every rc is resolved against the repo before the matrix sees it, whether or
    # not a source-branch was given: the branch state both fills the default AND
    # decides whether an explicit main is legal. Done here rather than inside
    # resolve_target to keep that helper pure. The probe is read-only, so it runs
    # in dry-run too and the routing a dry-run prints is the routing a real cut
    # would take. branch_exists aborts via `exit` on a transient failure and
    # resolve_rc_source returns non-zero on a refused main, and neither escapes a
    # command substitution on its own, so both are re-raised here.
    if [[ "$suffix" == "rc" ]]; then
      if ! source_branch="$(resolve_rc_source "$REPO" "$line" "$source_branch")"; then
        exit 1
      fi
    elif [[ "$suffix" == "alpha" || "$suffix" == "beta" ]]; then
      require_unbranched "$REPO" "$line" "$suffix"
    fi
    target="$(resolve_target "$suffix" "$source_branch" "$line")" || exit 1
  fi

  cut_release "$version" "$target"
}

# Only auto-run when executed directly; sourcing (e.g. from bats) must not.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

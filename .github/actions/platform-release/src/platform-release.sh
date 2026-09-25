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

# require_yq - hard error unless mikefarah yq v4.46.1 or later is on PATH. The
# preflight reads the workflow with it, and the python yq wrapper shares the
# name but not the language, so a wrong yq would misread rather than fail.
# GitHub-hosted Ubuntu runners ship a current mikefarah yq. 4.46.1 is the oldest
# release the workflow_facts expression was checked against.
require_yq() {
  local out major minor patch
  if ! command -v yq >/dev/null 2>&1; then
    echo "::error::yq is not on PATH. This action reads release.yaml with mikefarah yq v4.46.1 or later, which GitHub-hosted Ubuntu runners include. Nothing was tagged." >&2
    exit 1
  fi
  if ! out="$(yq --version 2>&1)"; then
    echo "::error::yq is on PATH at $(command -v yq) but could not run: $(flatten "$out"). This action needs a working mikefarah yq v4.46.1 or later. Nothing was tagged." >&2
    exit 1
  fi
  out="$(flatten "$out")"
  if [[ ! "$out" =~ mikefarah/yq.*version\ v?([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    echo "::error::yq on PATH is not mikefarah yq (it reports '${out}'). This action needs mikefarah yq v4.46.1 or later. Nothing was tagged." >&2
    exit 1
  fi
  major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
  if ((major != 4 || minor < 46 || (minor == 46 && patch < 1))); then
    echo "::error::mikefarah yq ${major}.${minor}.${patch} is on PATH, and this action needs v4.46.1 or later within v4. Nothing was tagged." >&2
    exit 1
  fi
}

# workflow_facts - read a workflow on stdin and print what the preflight needs,
# one fact per line:
#   merge_keys <n>                 `<<` merge keys anywhere in the file
#   duplicate_keys <n>             mappings that repeat a key
#   trigger <name>                 one per trigger, in any of the three spellings
#   bad_triggers <n>               triggers whose names cannot be printed
#   bad_inputs <n>                 workflow_dispatch inputs whose names cannot be printed
#   input <name> <req> <default>   one per workflow_dispatch input, flags 0 or 1;
#                                  a null or empty-string default does not count
# Merge and duplicate keys are counted before aliases are expanded, since
# expanding hides them. Only string keys shaped like event and input names are
# printed, which keeps a key carrying a newline from forging a line. The rest
# are counted instead, so the preflight can refuse what it cannot see.
#
# Two yq quirks shape the expression: a string literal after a pipe ignores an
# empty input (so every line is built from the data it reports, and the flags
# are array lengths), and a comma branch after `as $var` drops extra results (so
# the lines are collected into one array first).
workflow_facts() {
  # shellcheck disable=SC2016 # $on, $inputs and friends are yq variables
  yq -r '
    select(document_index == 0) |
    ([.. | select(tag == "!!map") | keys | .[] | select(tag == "!!merge")] | length) as $merges |
    ([.. | select(tag == "!!map") | select((keys | length) != (keys | unique | length))] | length) as $dups |
    explode(.) | .on as $on |
    ($on | select(tag == "!!map") | .workflow_dispatch | select(tag == "!!map") | .inputs | select(tag == "!!map")) as $inputs |
    [
      ("merge_keys " + ($merges | tostring)),
      ("duplicate_keys " + ($dups | tostring)),
      ($on | select(tag == "!!str") | select(test("^[a-z_]+$")) | "trigger " + .),
      ($on | select(tag == "!!seq") | .[] | select(tag == "!!str") | select(test("^[a-z_]+$")) | "trigger " + .),
      ($on | select(tag == "!!map") | keys | .[] | select(tag == "!!str") | select(test("^[a-z_]+$")) | "trigger " + .),
      ("bad_triggers " + ([
        ($on | select(tag == "!!str") | select(test("^[a-z_]+$") == false)),
        ($on | select(tag == "!!seq") | .[] | select(tag != "!!str" or (tag == "!!str" and test("^[a-z_]+$") == false))),
        ($on | select(tag == "!!map") | keys | .[] | select(tag != "!!str" or (tag == "!!str" and test("^[a-z_]+$") == false)))
      ] | length | tostring)),
      ("bad_inputs " + ([$inputs | keys | .[] | select(tag != "!!str" or (tag == "!!str" and test("^[A-Za-z0-9_-]+$") == false))] | length | tostring)),
      ($inputs | to_entries | .[] | select(.key | tag == "!!str") | select(.key | test("^[A-Za-z0-9_-]+$")) |
        "input " + .key + " " +
        ([.value | select(tag == "!!map") | .required | select((tag == "!!bool" or tag == "!!str") and ((tostring | downcase) == "true"))] | length | tostring) + " " +
        ([.value | select(tag == "!!map") | select(has("default")) | .default |
          select(tag != "!!null") | select((tag == "!!str" and length == 0) | not)] | length | tostring))
    ] | .[]
  '
}

# require_dispatchable <repo> <ref> <workflow> <tag> [label] - refuse to tag when
# the workflow about to be dispatched cannot be dispatched at that ref, or could
# start a build of its own. The ref is a commit sha in a real cut, so `label`
# carries the branch name the operator typed into the messages; it defaults to
# the ref for a direct call.
#
# The tag is created BEFORE the dispatch. A failed dispatch leaves the tag in
# place for the re-run to resume from, but the repo's tag-push workflows have
# already fired for it. Dry-run skips the dispatch, and the workflows API
# answers for the default branch rather than for an arbitrary ref, so reading
# the file at the ref is the only way to catch it before the tag exists.
#
# Read-only, so it runs in dry-run too: a dry-run against an unconverted line
# fails instead of printing a cut that would strand a tag.
require_dispatchable() {
  local repo="$1" ref="$2" wf="$3" tag="$4" label="${5:-$2}" body err
  # Only the failure branch needs gh's stderr, so it is captured separately
  # rather than merged in, where a notice would become part of the YAML read.
  if ! run_captured body err gh api "repos/${repo}/contents/.github/workflows/${wf}?ref=${ref}" -H "Accept: application/vnd.github.raw"; then
    echo "::error::could not read .github/workflows/${wf} at '${label}' in ${repo}, so the cut cannot confirm the build is dispatchable. Nothing was tagged. gh said: $(gh_reason "$err")" >&2
    exit 1
  fi
  # A workflow yq cannot parse cannot be dispatched either. Only yq's `Error:`
  # line is quoted: the warnings it prints first would push the reason past
  # where GitHub truncates an annotation.
  local facts reason_line
  if ! run_captured facts err workflow_facts <<<"$body"; then
    reason_line="$(grep -m1 '^Error:' <<<"$err" || printf '%s' "$err")"
    echo "::error::${wf} at '${label}' in ${repo} is not YAML this preflight can parse, so it cannot confirm the dispatch would succeed before the tag is created. Nothing was tagged. yq said: $(flatten "$reason_line")" >&2
    exit 1
  fi
  # Read once. `seen` holds the trigger lines as printed; inputs keep their
  # declaration order so the messages below list them the same way.
  local -A seen=() required=() has_default=()
  local -a inputs=()
  local kind name req def merges=0 dups=0 bad=0 bad_triggers=0
  while read -r kind name req def; do
    case "$kind" in
      merge_keys) merges="$name" ;;
      duplicate_keys) dups="$name" ;;
      bad_inputs) bad="$name" ;;
      bad_triggers) bad_triggers="$name" ;;
      input) inputs+=("$name"); required["$name"]="$req"; has_default["$name"]="$def" ;;
      ?*) seen["$kind $name"]=1 ;;
    esac
  done <<<"$facts"
  # GitHub's workflow parser supports anchors and aliases but not `<<` merge
  # keys, and rejects a repeated key, so either one would fail the dispatch
  # after the tag exists even though yq reads the file happily.
  if [[ "$merges" != "0" || "$dups" != "0" ]]; then
    echo "::error::${wf} at '${label}' in ${repo} uses a YAML merge key (<<) or repeats a key, which GitHub Actions does not accept, so the dispatch would fail after the tag was created. Write the keys out in full, once each. Nothing was tagged." >&2
    exit 1
  fi
  # All three spellings of `on:` list their triggers, and only the immediate
  # children of `on:` count: a deeper key named `workflow_dispatch` or `push`
  # (an input, a choice option) is not a trigger.
  if [[ -z "${seen[trigger workflow_dispatch]:-}" ]]; then
    echo "::error::${wf} at '${label}' in ${repo} has no workflow_dispatch trigger, so the dispatch would fail after the tag was created. Convert that line's ${wf} to workflow_dispatch (release-as-output) before cutting it. Nothing was tagged." >&2
    exit 1
  fi
  # The tag is an input to ONE build, the dispatched one, and the GitHub Release
  # is that build's output. Only workflow_dispatch and workflow_call are allowed,
  # since neither fires on its own. Any other trigger is refused whatever its
  # filters say: push and create fire for the tag, release fires when the
  # dispatched build publishes, and the rest have no business in a release
  # workflow. Reading GitHub's filter rules here would be a second copy of them
  # to keep in step. release.yaml itself also refuses to build on anything but a
  # dispatch, so this check is the early warning, not the only guard.
  local other="" entry
  for entry in "${!seen[@]}"; do
    [[ "$entry" == "trigger "* ]] || continue
    case "${entry#trigger }" in
      workflow_dispatch | workflow_call) ;;
      *) other+="${other:+, }${entry#trigger }" ;;
    esac
  done
  if [[ "$bad_triggers" != "0" ]]; then
    other+="${other:+, }${bad_triggers} whose name is not a GitHub event"
  fi
  if [[ -n "$other" ]]; then
    echo "::error::${wf} at '${label}' in ${repo} triggers on more than workflow_dispatch (${other}), so it could start a second build of the tag racing the dispatched one for the release. Leave only workflow_dispatch (and workflow_call, if other workflows call it) - the dispatched build creates the release. Nothing was tagged." >&2
    exit 1
  fi
  # An input whose name cannot be quoted back safely cannot be checked either.
  # GitHub only allows letters, digits, `-` and `_` there anyway.
  if [[ "$bad" != "0" ]]; then
    echo "::error::${wf} at '${label}' in ${repo} declares workflow_dispatch input names outside letters, digits, '-' and '_', which this preflight cannot check, so it cannot confirm the dispatch would succeed before the tag is created. Nothing was tagged." >&2
    exit 1
  fi
  # Only workflow_dispatch's own inputs count. A release.yaml that is also
  # callable declares triggered_by under workflow_call for its callers, and that
  # says nothing about what `gh workflow run` accepts.
  #
  # `gh workflow run` rejects an undeclared input, and the dispatch below passes
  # triggered_by whenever it is set, so a line that predates that input fails
  # after the tag exists.
  #
  # Matched exactly. Whether the API would accept `-f triggered_by` for an input
  # declared as `Triggered_By` is not something this preflight can confirm, and
  # guessing wrong fails the cut after the tag exists, so a differently cased
  # declaration is refused by name instead.
  if [[ -n "${TRIGGERED_BY}" && -z "${required[triggered_by]+x}" ]]; then
    local cased=""
    for name in "${inputs[@]}"; do
      [[ "${name,,}" == "triggered_by" ]] && cased="$name"
    done
    if [[ -n "$cased" ]]; then
      echo "::error::${wf} at '${label}' in ${repo} declares '${cased}' under workflow_dispatch, but this cut passes 'triggered_by'. Rename the input to 'triggered_by' in that line's ${wf}. Nothing was tagged." >&2
    else
      echo "::error::${wf} at '${label}' in ${repo} declares no 'triggered_by' input under workflow_dispatch, and \`gh workflow run\` rejects an undeclared input, so the dispatch would fail after the tag was created. Add the input to that line's ${wf}. Nothing was tagged." >&2
    fi
    exit 1
  fi
  # The mirror image: an input this cut does NOT pass, declared required with no
  # default, 422s with "Required input not provided" - again after the tag
  # exists. The dispatch sends triggered_by and nothing else. A required input
  # that has a default is fine; the API fills it in. An empty-string default is
  # not counted, since an empty value may itself read as not provided.
  local unsatisfiable=""
  for name in "${inputs[@]}"; do
    [[ "${required[$name]}" == "1" && "${has_default[$name]}" == "0" ]] || continue
    [[ -n "${TRIGGERED_BY}" && "$name" == "triggered_by" ]] && continue
    unsatisfiable+="${unsatisfiable:+, }${name}"
  done
  if [[ -n "$unsatisfiable" ]]; then
    echo "::error::${wf} at '${label}' in ${repo} declares required workflow_dispatch input(s) with no default that this cut does not pass (${unsatisfiable}), so the dispatch would fail after the tag was created. Give them a default in that line's ${wf}, or make them optional. Nothing was tagged." >&2
    exit 1
  fi
}

# require_workflow_active <repo> <workflow> - refuse to tag when GitHub would
# not run <workflow> at all. A disabled workflow, or one GitHub has not
# registered, fails the dispatch whatever the file at the ref says, and GitHub
# keeps that state per workflow rather than per ref, which is why this is a
# second read next to require_dispatchable.
require_workflow_active() {
  local repo="$1" wf="$2" state
  if ! api_get state "repos/${repo}/actions/workflows/${wf}" "workflow ${wf} in ${repo}" '.state'; then
    echo "::error::GitHub does not list ${wf} as a workflow in ${repo}, so \`gh workflow run\` cannot dispatch it. Nothing was tagged." >&2
    exit 1
  fi
  if [[ "$state" != "active" ]]; then
    echo "::error::${wf} in ${repo} is $(flatten "$state"), not active, so the dispatch would fail after the tag was created. Enable it before cutting. Nothing was tagged." >&2
    exit 1
  fi
}

# check_release_state <repo> <tag> - how far an earlier cut of this version got,
# and whether this one may carry on from there. Sets EXISTING_TAG_SHA to the
# tagged commit when the tag already exists and the cut should resume at the
# dispatch, or to empty when nothing exists yet and the cut starts from the tag.
#
# Refused:
#   - a published release: the version shipped, and releases are cut once
#   - a draft release: goreleaser drafts the release before uploading and
#     publishes it last, so a draft is a build still running or one that died
#     mid-upload. Promotion cannot finish a draft, and building again beside it
#     leaves two, so a human deletes it first. The draft is read against the
#     runs, so the error says whether to wait or delete
#   - a build still running under the tag name, whether or not the tag still
#     exists: dispatching again would race it
#   - a build that passed at the tag: it should have published, so something
#     needs a human, and another build could publish the version twice
# Resumed: a tag with no build at all, or only failed or cancelled builds. The
# tag stays where the first cut put it. Moving it would change what ships under
# a version that already has builds recorded against it.
#
# The action never deletes a tag. A failed dispatch leaves the tag in place and
# the re-run lands here.
check_release_state() {
  local repo="$1" tag="$2" listing err draft=0
  local inspect="Inspect: gh run list --repo ${repo} --workflow ${WORKFLOW} --branch ${tag}"
  EXISTING_TAG_SHA=""
  # One listing answers for published and draft releases alike. The singular
  # releases/tags/ endpoint cannot replace it, since it never returns a draft.
  # Drafts only appear to a token that can push, which require_push_access has
  # checked. A failed listing aborts rather than reading as "not released".
  if ! run_captured listing err gh api --paginate "repos/${repo}/releases?per_page=100" --jq '.[] | "\(.draft) \(.tag_name)"'; then
    echo "::error::could not list releases in ${repo} to check for ${tag}. Not treating as absent. gh said: $(gh_reason "$err")" >&2
    exit 1
  fi
  if grep -Fxq -- "false ${tag}" <<<"$listing"; then
    echo "::error::release ${tag} already exists in ${repo}. Refusing to re-cut (double-cut guard)." >&2
    exit 1
  fi
  if grep -Fxq -- "true ${tag}" <<<"$listing"; then
    draft=1
  fi
  # Read before the tag probe, because a missing tag does not prove nothing is
  # building: the tag can be deleted under a running build, and re-creating it
  # at the branch head would start a second build of the version from another
  # commit. Only runs that have not completed block. Run records outlive the tag,
  # so blocking on any run ever would stop the delete-and-re-cut path for good.
  local runs
  if ! tag_runs runs "$repo" "$WORKFLOW" "$tag"; then
    echo "::error::could not list ${WORKFLOW} runs at ${tag} in ${repo}, so the cut cannot tell whether a build is already running. Nothing was dispatched. gh said: $(gh_reason "$TAG_RUNS_ERR")" >&2
    exit 1
  fi
  local sha="" tagged=0
  # Singular `git/ref/tags/` requires an exact match (404s otherwise). The plural
  # `git/refs/tags/` prefix-matches, so it would report `v4.11.2` as existing when
  # only `v4.11.2-rc.1` had been tagged.
  if api_exists "repos/${repo}/git/ref/tags/${tag}" "tag ${tag} in ${repo}"; then
    tagged=1
    sha="$(tag_commit "$repo" "$tag")" || exit 1
  fi
  local id run_sha status conclusion
  while read -r id run_sha status conclusion; do
    [[ -n "$id" ]] || continue
    # Any sha: a build still running under this tag name races a new one
    # whichever commit it started from.
    if [[ "$status" != "completed" ]]; then
      if ((tagged)); then
        echo "::error::a ${WORKFLOW} run for ${tag} in ${repo} is still ${status}. Wait for it to finish, then re-run the cut if it fails. Nothing was dispatched. ${inspect}" >&2
      else
        echo "::error::a ${WORKFLOW} run for ${tag} in ${repo} is still ${status}, but tag ${tag} no longer exists. Re-creating it would start a second build of ${tag} from another commit. Wait for that run to finish, or cancel it, before cutting ${tag} again. Nothing was tagged. ${inspect}" >&2
      fi
      exit 1
    fi
    if ((tagged)) && [[ "$run_sha" == "$sha" && "$conclusion" == "success" ]]; then
      local missing="there is no release for ${tag}"
      ((draft)) && missing="the release for ${tag} is still a draft"
      echo "::error::a ${WORKFLOW} run for ${tag} in ${repo} already passed, but ${missing}. Check why that build did not publish before building ${tag} again. Nothing was dispatched. ${inspect}" >&2
      exit 1
    fi
  done <<<"$runs"
  if ((draft)); then
    local next
    if ((tagged)); then
      next="The re-run resumes at the existing tag, ${sha}."
    else
      next="Tag ${tag} no longer exists, so the re-run tags the current branch head, which may not be the commit the draft was built from."
    fi
    echo "::error::a draft release for ${tag} already exists in ${repo}, and no ${WORKFLOW} run at ${tag} is still going. Delete the draft and keep the tag: gh release delete ${tag} --repo ${repo} (without --cleanup-tag). Then re-run this cut. ${next} Nothing was dispatched. ${inspect}" >&2
    exit 1
  fi
  EXISTING_TAG_SHA="$sha"
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
  if [[ -n "$EXISTING_TAG_SHA" ]]; then
    # A resumed cut builds the commit the tag already points at, so that is the
    # release.yaml the preflight has to read, whatever the branch head is now.
    require_tag_on_target "$REPO" "$target" "$version" "$EXISTING_TAG_SHA"
    echo "::notice::tag ${version} already exists at ${EXISTING_TAG_SHA} on ${target} with no release and no build running or passed; resuming at the dispatch without re-tagging."
    sha="$EXISTING_TAG_SHA" label="$version"
  else
    # Resolved once and used for both the preflight read and the tag, since the
    # branch is a moving ref. Read in dry-run too, so the preview names the
    # commit it would tag.
    sha="$(resolve_head "$REPO" "$target")" || exit 1
    label="$target"
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

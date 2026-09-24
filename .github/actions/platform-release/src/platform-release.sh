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
#   push <tag>                     the tag of the push trigger's value, map form only
#   bad_push_filters <n>           keys under a mapped push trigger that cannot be printed
#   push_filter <key> <ok> <empty> one per key under a mapped push trigger. ok is
#                                  1 for a non-empty pattern or list of them,
#                                  empty is 1 for null, "" or []; neither is a
#                                  value of some other shape
#   push_pattern <key> <pattern>   one per tags/tags-ignore pattern, in order
#   push_bad_patterns <key> <n>    tags/tags-ignore patterns that cannot be printed
#   bad_inputs <n>                 workflow_dispatch inputs whose names cannot be printed
#   input <name> <req> <default>   one per workflow_dispatch input, flags 0 or 1;
#                                  a null or empty-string default does not count
# Merge and duplicate keys are counted before aliases are expanded, since
# expanding hides them. Only string keys shaped like event, filter and input
# names are printed, which keeps a key carrying a newline from forging a line.
# The rest are counted instead, so the preflight can refuse what it cannot see.
#
# Patterns are only ever checked with test(), never ==, because yq's == treats
# `*` as a glob.
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
      ($on | select(tag == "!!map") | select(has("push")) | "push " + (.push | tag)),
      ("bad_push_filters " + ([$on | select(tag == "!!map") | .push | select(tag == "!!map") | keys | .[] |
        select(tag != "!!str" or (tag == "!!str" and test("^[a-z-]+$") == false))] | length | tostring)),
      ($on | select(tag == "!!map") | .push | select(tag == "!!map") | to_entries | .[] |
        select(.key | tag == "!!str") | select(.key | test("^[a-z-]+$")) |
        "push_filter " + .key + " " +
        ([.value | select((tag == "!!str" and length > 0) or
          (tag == "!!seq" and length > 0 and ([.[] | select(tag == "!!str" and length > 0)] | length) == length))] | length | tostring) + " " +
        ([.value | select(tag == "!!null" or ((tag == "!!str" or tag == "!!seq") and length == 0))] | length | tostring)),
      ($on | select(tag == "!!map") | .push | select(tag == "!!map") | to_entries | .[] |
        select(.key == "tags" or .key == "tags-ignore") | .key as $k |
        [.value | (select(tag == "!!str"), (select(tag == "!!seq") | .[] | select(tag == "!!str")))] as $pats |
        (("push_bad_patterns " + $k + " " + ([$pats[] | select(test("^[A-Za-z0-9._/*?+!-]+$") | not)] | length | tostring)),
         ($pats[] | select(test("^[A-Za-z0-9._/*?+!-]+$")) | "push_pattern " + $k + " " + .))),
      ("bad_inputs " + ([$inputs | keys | .[] | select(tag != "!!str" or (tag == "!!str" and test("^[A-Za-z0-9_-]+$") == false))] | length | tostring)),
      ($inputs | to_entries | .[] | select(.key | tag == "!!str") | select(.key | test("^[A-Za-z0-9_-]+$")) |
        "input " + .key + " " +
        ([.value | select(tag == "!!map") | .required | select((tag == "!!bool" or tag == "!!str") and ((tostring | downcase) == "true"))] | length | tostring) + " " +
        ([.value | select(tag == "!!map") | select(has("default")) | .default |
          select(tag != "!!null") | select((tag == "!!str" and length == 0) | not)] | length | tostring))
    ] | .[]
  '
}

# filter_regex <pattern> -> an anchored ERE for a GitHub branch/tag filter
# pattern, or return 1 for one this does not translate. Covers `*` (no `/`),
# `**`, and `?`/`+` on the preceding character. Anything else, a `[...]` class
# or an escape included, never reaches here: workflow_facts only prints
# patterns made of letters, digits and `._/*?+!-`, and a `!` past the first
# character, or a `?`/`+` with nothing plain before it, is refused here.
# Refusing is safe, since the caller then refuses the cut rather than guess.
filter_regex() {
  local p="$1" out="" c prev="" i=0
  while ((i < ${#p})); do
    c="${p:i:1}"
    case "$c" in
      '*')
        if [[ "${p:i+1:1}" == '*' ]]; then out+='.*'; i=$((i + 1)); else out+='[^/]*'; fi
        prev='*' ;;
      '?' | '+')
        [[ -n "$prev" && "$prev" != '*' && "$prev" != '?' && "$prev" != '+' ]] || return 1
        out+="$c"; prev="$c" ;;
      '.') out+='\.'; prev="$c" ;;
      '!') return 1 ;;
      *) out+="$c"; prev="$c" ;;
    esac
    i=$((i + 1))
  done
  printf '^%s$' "$out"
}

# tag_push_fires <tag> <tags|tags-ignore> <pattern...> -> 0 if a push of <tag>
# fires under that filter, 1 if it does not, 2 if a pattern cannot be read.
# Under `tags` the last pattern that matches decides, and a leading `!` makes a
# match exclude. Under `tags-ignore` any match excludes, and `!` has no meaning.
tag_push_fires() {
  local tag="$1" key="$2" p neg re fires
  shift 2
  if [[ "$key" == "tags" ]]; then fires=1; else fires=0; fi
  for p in "$@"; do
    neg=0
    if [[ "$key" == "tags" && "$p" == '!'* ]]; then neg=1; p="${p:1}"; fi
    re="$(filter_regex "$p")" || return 2
    [[ "$tag" =~ $re ]] || continue
    if [[ "$key" == "tags-ignore" ]]; then return 1; fi
    fires="$neg"
  done
  return "$fires"
}

# require_dispatchable <repo> <ref> <workflow> <tag> [label] - refuse to tag when
# the workflow about to be dispatched cannot be dispatched at that ref, or would
# also fire for the push of <tag>. The ref is a commit sha in a real cut, so
# `label` carries the branch name the operator typed into the messages; it
# defaults to the ref for a direct call.
#
# The tag is created BEFORE the dispatch. A failed dispatch leaves the tag in
# place for the re-run to resume from, but the repo's tag-push workflows have
# already fired for it, and a release.yaml that also triggers on the tag or the
# release does not fail the dispatch at all: it races it. Dry-run skips the dispatch, and
# the workflows API answers for the default branch rather than for an arbitrary
# ref, so reading the file at the ref is the only way to catch either before the
# tag exists.
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
  # Read once. `seen` holds the trigger and push lines as printed; inputs keep
  # their declaration order so the messages below list them the same way, and
  # tag patterns keep theirs because under `tags` the last match decides.
  local -A seen=() required=() has_default=() filter_ok=() filter_empty=()
  local -a inputs=() tag_patterns=()
  local kind name req def merges=0 dups=0 bad=0 bad_patterns=0 bad_triggers=0 bad_filters=0
  while read -r kind name req def; do
    case "$kind" in
      merge_keys) merges="$name" ;;
      duplicate_keys) dups="$name" ;;
      bad_inputs) bad="$name" ;;
      bad_triggers) bad_triggers="$name" ;;
      bad_push_filters) bad_filters="$name" ;;
      push_filter) filter_ok["$name"]="$req"; filter_empty["$name"]="$def" ;;
      push_pattern) tag_patterns+=("$req") ;;
      push_bad_patterns) bad_patterns=$((bad_patterns + req)) ;;
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
  # GitHub event names are lowercase letters and `_`, so anything else under
  # `on:` is an event GitHub does not know, and it rejects the file.
  if [[ "$bad_triggers" != "0" ]]; then
    echo "::error::${wf} at '${label}' in ${repo} has a trigger under on: whose name is not a GitHub event (event names are lowercase letters and '_'), so the dispatch would fail after the tag was created. Nothing was tagged." >&2
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
  # is that build's output. A release.yaml that also fires on the tag push starts
  # a second build the moment create_tag runs, and the two race for the release.
  # This catches the half-converted shape (workflow_dispatch added, old trigger
  # left behind): the tag push here, `release:`/`create:` below.
  #
  # Only a push that fires for THIS tag counts. With a `tags` or `tags-ignore`
  # filter the patterns decide, and they are matched against the tag being cut.
  # With neither, a `branches`/`branches-ignore` filter means tags never fire,
  # and no filter at all means they always do. `paths` filters by changed file
  # and is not evaluated for a tag push, so it restricts nothing here.
  if [[ -n "${seen[trigger push]:-}" && -n "${seen[push !!map]:-}" ]]; then
    if [[ "$bad_filters" != "0" ]]; then
      echo "::error::${wf} at '${label}' in ${repo} has a key under push that is not a push filter GitHub accepts (branches, branches-ignore, tags, tags-ignore, paths, paths-ignore), so the dispatch would fail after the tag was created. Nothing was tagged." >&2
      exit 1
    fi
    local key
    for key in "${!filter_ok[@]}"; do
      case "$key" in
        branches | branches-ignore | tags | tags-ignore | paths | paths-ignore) ;;
        *)
          echo "::error::${wf} at '${label}' in ${repo} has '${key}' under push, which is not a push filter GitHub accepts, so the dispatch would fail after the tag was created. Nothing was tagged." >&2
          exit 1 ;;
      esac
      # Whether GitHub reads an empty filter as absent or as matching nothing
      # is not something this preflight can confirm, and one reading races the
      # dispatched build while the other rejects the file.
      if [[ "${filter_ok[$key]}" != "1" ]]; then
        local shape="a value that is not a pattern or a list of them"
        [[ "${filter_empty[$key]}" == "1" ]] && shape="no patterns"
        echo "::error::${wf} at '${label}' in ${repo} has a push '${key}' filter with ${shape}, so this preflight cannot confirm what it matches. List its patterns, or remove the key. Nothing was tagged." >&2
        exit 1
      fi
    done
    local pair
    for pair in branches tags paths; do
      if [[ -n "${filter_ok[$pair]:-}" && -n "${filter_ok[$pair-ignore]:-}" ]]; then
        echo "::error::${wf} at '${label}' in ${repo} sets both '${pair}' and '${pair}-ignore' under push, which GitHub does not accept for the same event, so the dispatch would fail after the tag was created. Keep one of them. Nothing was tagged." >&2
        exit 1
      fi
    done
  fi
  local reason="" tag_key="" fires_rc
  [[ -n "${filter_ok[tags]:-}" ]] && tag_key="tags"
  [[ -n "${filter_ok[tags-ignore]:-}" ]] && tag_key="tags-ignore"
  if [[ -n "${seen[trigger push]:-}" ]]; then
    if [[ -z "${seen[push !!map]:-}" ]]; then
      # The list and scalar spellings, a bare `push:`, or a value that is not a
      # mapping: none of them carries a filter.
      reason="unfiltered, so it fires for tags too"
    elif [[ -n "$tag_key" ]]; then
      fires_rc=0
      if [[ "$bad_patterns" == "0" ]]; then
        tag_push_fires "$tag" "$tag_key" "${tag_patterns[@]}" || fires_rc=$?
      else
        fires_rc=2
      fi
      case "$fires_rc" in
        0) reason="its ${tag_key} filter does not exclude ${tag}" ;;
        1) ;;
        *)
          echo "::error::${wf} at '${label}' in ${repo} has a push ${tag_key} pattern this preflight cannot evaluate (it reads letters, digits, '.', '_', '-', '/', '*', '**', '?', '+' and a leading '!' under tags), so it cannot confirm the tag push would not start a second build. Nothing was tagged." >&2
          exit 1 ;;
      esac
    elif [[ -z "${filter_ok[branches]:-}${filter_ok[branches-ignore]:-}" ]]; then
      reason="not filtered to branches, so it fires for tags too"
    fi
  fi
  if [[ -n "$reason" ]]; then
    echo "::error::${wf} at '${label}' in ${repo} still triggers on push (${reason}), so creating the tag would start a second build racing the dispatched one for the release. Remove that trigger from the line's ${wf} - the dispatched build creates the release. Nothing was tagged." >&2
    exit 1
  fi
  # The same premise from the other end. `release:` fires when the dispatched
  # build creates the release, `create:` fires on the tag itself - either one a
  # second build of the tag just cut. Refused whatever `types:` says, unlike
  # push: no filter on these keeps them from firing for this cut.
  local event why
  for event in release create; do
    if [[ -n "${seen[trigger $event]:-}" ]]; then
      case "$event" in
        release) why="which fires when the dispatched build creates the release" ;;
        *) why="which fires for the tag this creates" ;;
      esac
      echo "::error::${wf} at '${label}' in ${repo} still triggers on ${event} (${why}), so it would start a second build racing the dispatched one for the release. Remove that trigger from the line's ${wf} - the dispatched build creates the release. Nothing was tagged." >&2
      exit 1
    fi
  done
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

# tag_commit <repo> <tag> - the commit an existing tag points at, peeled when the
# tag is annotated, since a workflow run reports the peeled commit as head_sha.
# create_tag only writes lightweight tags, but a hand-made one can be annotated.
# Aborts when the commit cannot be read, rather than guessing which build the
# tag belongs to.
tag_commit() {
  local repo="$1" tag="$2" out sha type
  if ! api_get out "repos/${repo}/git/ref/tags/${tag}" "tag ${tag} in ${repo}" '"\(.object.sha // "") \(.object.type // "")"'; then
    echo "::error::tag ${tag} in ${repo} disappeared while the cut was reading it. Re-run the cut." >&2
    exit 1
  fi
  sha="${out%% *}" type="${out##* }"
  if [[ "$type" == "tag" && "$sha" =~ ^[0-9a-f]{40,64}$ ]]; then
    if ! api_get sha "repos/${repo}/git/tags/${sha}" "tag object ${tag} in ${repo}" '.object.sha // empty'; then
      sha=""
    fi
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{40,64}$ ]]; then
    echo "::error::tag ${tag} exists in ${repo} but the commit it points at could not be resolved, so the cut cannot tell which build belongs to it. Nothing was dispatched." >&2
    exit 1
  fi
  printf '%s' "$sha"
}

# check_release_state <repo> <tag> - how far an earlier cut of this version got,
# and whether this one may carry on from there. Sets EXISTING_TAG_SHA to the
# tagged commit when the tag already exists and the cut should resume at the
# dispatch, or to empty when nothing exists yet and the cut starts from the tag.
#
# Refused:
#   - a published release: the version shipped, and releases are cut once
#   - a draft release: a build got far enough to publish it, so the version is
#     finished by promoting the draft, not by building it again
#   - a build still running at the tag: dispatching again would race it
#   - a build that passed at the tag: it should have published, so something
#     needs a human, and another build could publish the version twice
# Resumed: a tag with no build at all, or only failed or cancelled builds. The
# tag stays where the first cut put it. Moving it would change what ships under
# a version that already has builds recorded against it.
#
# The action never deletes a tag. A failed dispatch leaves the tag in place and
# the re-run lands here.
check_release_state() {
  local repo="$1" tag="$2" listing err
  EXISTING_TAG_SHA=""
  # releases/tags/ answers for published releases only, and one request settles
  # the common double cut before the listing below.
  if api_exists "repos/${repo}/releases/tags/${tag}" "release ${tag} in ${repo}"; then
    echo "::error::release ${tag} already exists in ${repo}. Refusing to re-cut (double-cut guard)." >&2
    exit 1
  fi
  # Only a listing finds a draft. Drafts only appear to a token that can push,
  # which require_push_access has checked. A failed listing aborts rather than
  # reading as "not released".
  if ! run_captured listing err gh api --paginate "repos/${repo}/releases?per_page=100" --jq '.[] | "\(.draft) \(.tag_name)"'; then
    echo "::error::could not list releases in ${repo} to check for ${tag}. Not treating as absent. gh said: $(gh_reason "$err")" >&2
    exit 1
  fi
  if grep -Fxq -- "false ${tag}" <<<"$listing"; then
    echo "::error::release ${tag} already exists in ${repo}. Refusing to re-cut (double-cut guard)." >&2
    exit 1
  fi
  if grep -Fxq -- "true ${tag}" <<<"$listing"; then
    echo "::error::a draft release for ${tag} already exists in ${repo}, left by an earlier build of this version. Promote the draft with ${repo}'s promote-release.yaml workflow instead of cutting ${tag} again. Do not delete it." >&2
    exit 1
  fi
  # Singular `git/ref/tags/` requires an exact match (404s otherwise). The plural
  # `git/refs/tags/` prefix-matches, so it would report `v4.11.2` as existing when
  # only `v4.11.2-rc.1` had been tagged.
  if ! api_exists "repos/${repo}/git/ref/tags/${tag}" "tag ${tag} in ${repo}"; then
    return 0
  fi
  local sha runs
  sha="$(tag_commit "$repo" "$tag")" || exit 1
  # `gh workflow run --ref refs/tags/<tag>` records the tag name as the run's
  # head_branch, which is what `branch=` filters on. The shape is asserted so an
  # error body cannot read as "no runs" and let a second build through. 100 runs
  # is far more than one tag ever collects.
  # shellcheck disable=SC2016 # jq, not shell
  if ! run_captured runs err gh api "repos/${repo}/actions/workflows/${WORKFLOW}/runs?branch=${tag}&per_page=100"     --jq 'if (.workflow_runs | type) != "array" then error("no workflow_runs array") else .workflow_runs[] | "\(.head_sha) \(.status) \(.conclusion // "none")" end'; then
    echo "::error::could not list ${WORKFLOW} runs at ${tag} in ${repo}, so the cut cannot tell whether a build is already running. Nothing was dispatched. gh said: $(gh_reason "$err")" >&2
    exit 1
  fi
  local run_sha status conclusion
  while read -r run_sha status conclusion; do
    [[ -n "$run_sha" ]] || continue
    # Any sha: a build still running under this tag name races a new one
    # whichever commit it started from.
    if [[ "$status" != "completed" ]]; then
      echo "::error::a ${WORKFLOW} run for ${tag} in ${repo} is still ${status}. Wait for it to finish, then re-run the cut if it fails. Nothing was dispatched. Inspect: gh run list --repo ${repo} --workflow ${WORKFLOW} --branch ${tag}" >&2
      exit 1
    fi
    if [[ "$run_sha" == "$sha" && "$conclusion" == "success" ]]; then
      echo "::error::a ${WORKFLOW} run for ${tag} in ${repo} already passed, but there is no release for ${tag}. Check why that build did not publish before building ${tag} again. Nothing was dispatched. Inspect: gh run list --repo ${repo} --workflow ${WORKFLOW} --branch ${tag}" >&2
      exit 1
    fi
  done <<<"$runs"
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

# resolve_head <repo> <branch> -> the branch head sha. Read once per cut, before
# the preflight, so the commit whose release.yaml is validated is the commit the
# tag lands on. A second read at tag time would let a push in between get tagged
# unvalidated.
#
# This read is also the existence check. The target is resolved from the suffix
# matrix, so it must already exist: stable names a release-X.Y branch that has
# to be cut first, alpha/beta name the default branch, next names a feature
# branch. A 404 is refused rather than swapped for another branch.
#
# Singular `git/ref/heads/`, for the same reason check_release_state uses the
# singular tags form: the plural endpoint falls back to prefix matching and
# answers with an ARRAY of near-misses when the exact ref is absent, where the
# singular form gives a clean 404.
#
# `.object.sha // empty` guards the jq null-string hazard: on an unexpected
# ref-response shape jq would otherwise print the literal "null" and exit 0
# (set -e does not catch it), producing a GitHub 422 "Invalid SHA" instead of
# a meaningful diagnostic.
resolve_head() {
  local repo="$1" branch="$2" sha
  if ! api_get sha "repos/${repo}/git/ref/heads/${branch}" "branch '${branch}' in ${repo}" '.object.sha // empty'; then
    echo "::error::branch '${branch}' not found in ${repo}. Create it (and its workflow_dispatch-enabled release.yaml) before cutting this line - refusing to guess." >&2
    return 1
  fi
  if [[ -z "$sha" ]]; then
    echo "::error::could not resolve HEAD sha for branch '${branch}' in ${repo}" >&2
    return 1
  fi
  printf '%s' "$sha"
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

# dispatch <repo> <tag> [extra gh flags...] - run that ref's release.yaml.
# --ref executes the tagged commit's version of the workflow, so each line
# builds with its own glue. It is the full ref, since a branch that shares the
# tag's name would otherwise be what GitHub runs.
dispatch() {
  local repo="$1" tag="$2"
  shift 2
  local extra=("$@")
  if [[ "${DRY_RUN:-true}" == "true" ]]; then
    echo "[dry-run] gh workflow run ${WORKFLOW} --repo ${repo} --ref refs/tags/${tag} ${extra[*]}"
    return 0
  fi
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
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

# cut_release <version> <target-branch> - the whole single-repo cut.
cut_release() {
  local version="$1" target="$2"
  echo "Routing ${version} -> ${REPO} (target ${target})"
  # Resolved once and used for both the preflight read and the tag, since the
  # branch is a moving ref. Read in dry-run too, so the preview names the commit
  # it would tag.
  local sha label="$target"
  sha="$(resolve_head "$REPO" "$target")" || exit 1
  check_release_state "$REPO" "$version"
  # A resumed cut builds the commit the tag already points at, so that is the
  # release.yaml the preflight has to read, whatever the branch head is now.
  if [[ -n "$EXISTING_TAG_SHA" ]]; then
    echo "::notice::tag ${version} already exists at ${EXISTING_TAG_SHA} with no release and no build running or passed; resuming at the dispatch without re-tagging (${target} head is ${sha})."
    sha="$EXISTING_TAG_SHA" label="$version"
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
  dispatch "$REPO" "$version" "${dispatch_args[@]}"
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

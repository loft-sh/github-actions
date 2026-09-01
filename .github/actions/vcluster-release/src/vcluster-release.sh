#!/usr/bin/env bash
# Single release dispatcher (DEVOPS-1050).
#
# One entry point for cutting a release on any supported line. The version
# string decides the routing; nobody has to remember which era a version is in.
#
# The GitHub Release is treated as a pipeline *output*, not a trigger: this
# script only creates the tag(s) and dispatches each line's own release.yaml via
# `gh workflow run --ref <tag>` (verified to run the tag's version of the
# workflow). The dispatched builder creates the release at the end of a green
# build. Nothing triggers on `release:created`, so a monorepo-created OSS release
# cannot re-trigger the OSS builder.
#
# The prerelease suffix decides which branch a version may be cut from
# (fail-closed - an unroutable suffix like -devpod.alpha is rejected, never
# guessed):
#   -alpha / -beta      -> main only
#   -rc                 -> main or the vX.Y release branch (default main)
#   stable (vX.Y.Z)     -> the vX.Y release branch only
#   -next / -next.internal -> a short-lived feature branch (source-branch input
#                         required); always builds pro only.
# The feature-branch prereleases short-circuit the era routing below; everything
# else routes by numeric (major, minor) compare against CUTOVER (v0.37):
#   legacy   (< v0.37) -> rc/stable only, from the vX.Y branch in BOTH repos;
#                         tag both, dispatch loft-sh/vcluster FIRST, then -pro.
#   monorepo (>= v0.37) -> tag the resolved branch in loft-sh/vcluster-pro,
#                         dispatch loft-sh/vcluster-pro only.
# v0.36 is a legacy line (two-repo dance); v0.37 is the first merged/monorepo line.
#
# dry_run (default true) performs the read-only checks (branch existence,
# double-cut guard) so the printed routing decision is validated, but prints the
# mutating tag/dispatch calls instead of firing them.
set -euo pipefail

CUTOVER="${CUTOVER:-v0.37}"
OSS_REPO="${OSS_REPO:-loft-sh/vcluster}"
PRO_REPO="${PRO_REPO:-loft-sh/vcluster-pro}"
WORKFLOW="${WORKFLOW:-release.yaml}"
# Legacy-line pro dependency bump. During a legacy cut, after the OSS tag is
# created, this workflow is dispatched on the pro default branch to bump the
# vendored github.com/loft-sh/vcluster dependency on the pro release branch to
# the new tag and open a loft-bot PR; auto-approve-bot-prs merges it. The
# WAIT_* bounds bound the poll for that merge and are overridable so the bats
# suite drives the poll without real sleeps.
BUMP_WORKFLOW="${BUMP_WORKFLOW:-release-bump-vcluster.yaml}"
PRO_DEFAULT_BRANCH="${PRO_DEFAULT_BRANCH:-main}"
PRO_OWNER="${PRO_REPO%%/*}"
# ~120 min ceiling (480 x 15s). Must exceed the bot's own CI wait: the bump PR
# triggers e2e and auto-approve-bot-prs only merges once e2e is green, so this
# poll has to outlast a full e2e run plus the merge.
BUMP_WAIT_ATTEMPTS="${BUMP_WAIT_ATTEMPTS:-480}"
BUMP_WAIT_SLEEP_SECONDS="${BUMP_WAIT_SLEEP_SECONDS:-15}"
# Consecutive poll API failures tolerated before the wait fails fast: a blip
# keeps polling, a sustained auth/repo failure aborts with the real cause
# instead of silently waiting out the full timeout.
BUMP_WAIT_MAX_API_FAILURES="${BUMP_WAIT_MAX_API_FAILURES:-5}"
# jq filter reducing the pulls list to "<state>|<merged_at>" for the newest PR;
# a null (no PR yet) collapses to "none|" via the // fallbacks so parsing never
# errors. Extracted so the bats suite can validate the exact expression.
BUMP_PR_JQ='.[0] | "\(.state // "none")|\(.merged_at // "")"'
# The human who invoked cut-release. Forwarded to the monorepo-era release.yaml
# (-f triggered_by=...) so the Slack banner attributes the person, not the bot
# PAT that dispatches the build. Only passed on paths whose release.yaml declares
# the input (monorepo + feature-prerelease); legacy release.yaml's don't have it,
# and gh workflow run rejects undeclared inputs, so legacy dispatches omit it.
TRIGGERED_BY="${TRIGGERED_BY:-}"

# ---------------------------------------------------------------------------
# Pure helpers (no network) - the routing brain, exhaustively unit-tested.
# ---------------------------------------------------------------------------

# normalize_version <raw> -> canonical vX.Y.Z[-suffix]
# Operators paste versions from Linear, Slack and release notes, where the
# leading v is inconsistent and a stray space survives a copy. The routing
# helpers below already tolerate both spellings (parse_major_minor strips an
# optional v), but the raw string is used VERBATIM as the tag name and as the
# double-cut probe key - so an un-normalized "0.37.1" would create a v-less tag
# AND sail past the double-cut guard, which probes for "v0.37.1" and gets a 404.
# That silently re-releases an already-shipped version, and the resulting tag can
# never be promoted (promote-release requires ^v[0-9]+\.[0-9]+\.[0-9]+$) nor be
# resolved by the Go module proxy, which requires the v. Normalizing here, before
# anything reads the value, makes both spellings land on the same canonical tag.
normalize_version() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"    # strip leading whitespace
  v="${v%"${v##*[![:space:]]}"}"    # strip trailing whitespace
  [[ "$v" == V* ]] && v="v${v#V}"   # accept a capitalized V
  [[ "$v" == v* ]] || v="v${v}"     # supply the leading v when missing
  printf '%s\n' "$v"
}

# validate_version <version> - hard-fail anything that is not our tag shape.
# Runs AFTER normalize_version, so a recoverable paste (missing v, capitalized V,
# stray whitespace) has already been repaired and only genuinely malformed input
# reaches here. Deliberately STRICTER than semver, because the value is used
# verbatim as a git tag and every downstream consumer assumes vMAJOR.MINOR.PATCH:
#   vX.Y     would create a tag colliding with the vX.Y release BRANCH, leaving an
#            ambiguous ref that git resolves with a warning.
#   vX.Y.Z.N is not semver at all.
#   0.37.1   bare semver is valid to node-semver but cannot be promoted
#            (promote-release matches ^v[0-9]+\.[0-9]+\.[0-9]+$) nor resolved by
#            the Go module proxy; normalize_version has already fixed it by here.
# Build metadata (+meta) is rejected too: no consumer in the pipeline handles it.
# The prerelease body is only shape-checked here - classify_suffix decides which
# suffixes are actually routable, and is fail-closed on unknown ones.
validate_version() {
  local v="$1"
  if [[ ! "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "::error::version '${v}' is not a valid release version. Expected vMAJOR.MINOR.PATCH with an optional prerelease suffix, e.g. v0.37.1, v0.37.0-rc.1, v0.37.0-next.internal.3." >&2
    return 1
  fi
}

# parse_major_minor <version> -> "MAJOR MINOR"
# Accepts v-prefixed or bare, with or without patch/prerelease:
#   v0.35.4-rc.1 -> "0 35", v1.0 -> "1 0". Fails loudly on garbage.
parse_major_minor() {
  local v="${1#v}" major minor rest
  major="${v%%.*}"
  rest="${v#*.}"
  minor="${rest%%.*}"
  # Trim any non-numeric suffix on the minor (e.g. "36-rc.1" -> "36").
  minor="${minor%%[!0-9]*}"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]]; then
    echo "::error::cannot parse major.minor from version '$1'" >&2
    return 1
  fi
  printf '%s %s\n' "$major" "$minor"
}

# derive_line <version> -> vX.Y
derive_line() {
  local mm major minor
  mm="$(parse_major_minor "$1")" || return 1
  read -r major minor <<<"$mm"
  printf 'v%s.%s\n' "$major" "$minor"
}

# classify_era <version> [cutover] -> "legacy" | "monorepo"
# (major, minor) >= (cutover major, minor) is monorepo; anything below is legacy.
classify_era() {
  local version="$1" cutover="${2:-$CUTOVER}" vmm cmm vmaj vmin cmaj cmin
  vmm="$(parse_major_minor "$version")" || return 1
  cmm="$(parse_major_minor "$cutover")" || return 1
  read -r vmaj vmin <<<"$vmm"
  read -r cmaj cmin <<<"$cmm"
  if (( vmaj > cmaj || (vmaj == cmaj && vmin >= cmin) )); then
    printf 'monorepo\n'
  else
    printf 'legacy\n'
  fi
}

# classify_suffix <version> -> alpha | beta | rc | next | next-internal | stable
# Fail-closed: only the prerelease suffixes the dispatcher knows how to route are
# accepted. Anything else - including a legal-but-unrouted tag such as
# -devpod.alpha - is rejected so an unhandled release type can never be silently
# misrouted onto the wrong branch. Order matters: -next.internal is a sub-flavor
# of -next and must be matched first.
classify_suffix() {
  local v="$1"
  case "$v" in
    *-next.internal.*) printf 'next-internal\n' ;;
    *-next.*)          printf 'next\n' ;;
    *-alpha.*)         printf 'alpha\n' ;;
    *-beta.*)          printf 'beta\n' ;;
    *-rc.*)            printf 'rc\n' ;;
    *-*)
      echo "::error::version '$v' has an unsupported prerelease suffix; the dispatcher cuts only -alpha/-beta/-rc/-next/-next.internal or a stable vX.Y.Z" >&2
      return 1 ;;
    *) printf 'stable\n' ;;
  esac
}

# is_feature_branch <branch> -> 0 for a short-lived feature branch, 1 otherwise.
# A feature branch is anything that is neither main nor a vX.Y release branch.
is_feature_branch() {
  local b="$1"
  [[ "$b" == "main" ]] && return 1
  [[ "$b" =~ ^v[0-9]+\.[0-9]+$ ]] && return 1
  return 0
}

# resolve_target <suffix> <source-branch> <line> -> the branch to tag, or a hard
# error if <source-branch> violates the matrix. Handles the non-feature suffixes
# only (alpha/beta/rc/stable); next/next.internal are routed by cut_feature_prerelease.
#   alpha|beta -> main only
#   rc         -> main or the line branch vX.Y (empty source-branch defaults to main)
#   stable     -> the line branch vX.Y only
resolve_target() {
  local suffix="$1" src="$2" line="$3"
  case "$suffix" in
    alpha|beta)
      if [[ -n "$src" && "$src" != "main" ]]; then
        echo "::error::${suffix} releases are cut from main only, not '${src}'" >&2
        return 1
      fi
      printf 'main\n' ;;
    rc)
      if [[ -z "$src" || "$src" == "main" ]]; then
        printf 'main\n'
      elif [[ "$src" == "$line" ]]; then
        printf '%s\n' "$line"
      else
        echo "::error::rc releases are cut from main or the ${line} release branch, not '${src}'" >&2
        return 1
      fi ;;
    stable)
      if [[ -n "$src" && "$src" != "$line" ]]; then
        echo "::error::stable releases are cut from the ${line} release branch only, not '${src}'" >&2
        return 1
      fi
      printf '%s\n' "$line" ;;
    *)
      echo "::error::resolve_target: unexpected suffix '${suffix}'" >&2
      return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Network helpers. Read-only ones always run (they validate the routing, even
# in dry-run). Mutating ones honour DRY_RUN.
# ---------------------------------------------------------------------------

# api_exists <path> <what> -> 0 if 200, 1 if 404, exits 1 on transient/unexpected.
# Shared read-only existence probe. Read only the HTTP status line. On a 404 `gh`
# exits non-zero, so we must capture its output with `|| true` BEFORE parsing -
# piping gh directly into the status-substitution would let pipefail propagate the
# non-zero exit and clobber the code to empty, misreading a real 404 as a transient
# failure. gh writes the "HTTP/2.0 404" status line to stdout even with --silent
# (only the body is suppressed); a genuine transient error (DNS/auth/rate-limit)
# yields no status line, so an empty code correctly means "could not reach the API".
# Distinguishing the two matters to every caller: an unreachable API must never be
# silently read as "absent" (a missed double-cut guard) or "missing" (a wrong branch).
api_exists() {
  local path="$1" what="$2" headers http_code
  headers="$(gh api "$path" --silent -i 2>/dev/null || true)"
  http_code="$(printf '%s\n' "$headers" | head -1 | awk '{print $2}')"
  case "$http_code" in
    200) return 0 ;;
    404) return 1 ;;
    "")
      echo "::error::failed to reach GitHub API for ${what} (no HTTP status - DNS, rate-limit, or auth). Not treating as absent." >&2
      exit 1
      ;;
    *)
      echo "::error::unexpected status ${http_code} from GitHub API for ${what}." >&2
      exit 1
      ;;
  esac
}

# branch_exists <repo> <branch> -> 0 if 200, 1 if 404, exits 1 on transient error.
branch_exists() {
  local repo="$1" branch="$2"
  api_exists "repos/${repo}/branches/${branch}" "branch '${branch}' in ${repo}"
}

# require_branch <repo> <branch> - hard error if the branch is absent.
require_branch() {
  local repo="$1" branch="$2"
  if ! branch_exists "$repo" "$branch"; then
    echo "::error::release branch '${branch}' not found in ${repo}. Create it (and its workflow_dispatch-enabled release.yaml) before cutting this line - refusing to guess." >&2
    exit 1
  fi
}

# workflow_runs_at_ref <repo> <ref> -> 0 if this line's release.yaml has already
# been dispatched at <ref>, 1 if it has not.
#
# `gh workflow run --ref <tag>` records the tag name verbatim in head_branch, and
# the runs endpoint's `branch=` filter matches on that field, so a tag ref
# queries cleanly here (verified against real dispatched release runs in both
# repos). This is what keeps a resume from firing a second build of a release
# that is already building.
#
# Fail-closed like api_exists: a probe that cannot answer must never read as
# "not dispatched", because that is the one wrong answer that duplicates a build.
workflow_runs_at_ref() {
  local repo="$1" ref="$2" status_filter="${3:-}" out rc=0 query
  query="repos/${repo}/actions/workflows/${WORKFLOW}/runs?branch=${ref}&per_page=1"
  [[ -n "$status_filter" ]] && query="${query}&status=${status_filter}"
  out="$(gh api "$query" --jq '.total_count // 0' 2>&1)" || rc=$?
  if (( rc != 0 )); then
    echo "::error::failed to list ${WORKFLOW} runs at ${ref} in ${repo}${status_filter:+ (status=${status_filter})} (needs actions:read on the token). Not treating as un-dispatched: $(printf '%s' "$out" | tr '\n' ' ')" >&2
    exit 1
  fi
  if [[ ! "$out" =~ ^[0-9]+$ ]]; then
    echo "::error::unexpected run-count response for ${ref} in ${repo}: $(printf '%s' "$out" | tr '\n' ' ')" >&2
    exit 1
  fi
  (( out > 0 ))
}

# release_state <repo> <tag> -> absent | tagged | dispatched | released
#
# How far a previous cut got for this version in this repo. Every mutating step
# is keyed off this so re-running the button resumes an interrupted cut instead
# of colliding with its own earlier progress. The states are ordered: each one
# implies every step before it is already done.
#
#   absent     nothing exists; do everything
#   tagged     tag created, build never dispatched
#   dispatched build dispatched (running, failed, or finished without publishing)
#   released   a GitHub Release exists - the pipeline's terminal output
#
# The release is the terminal marker precisely because this script treats it as
# an output, not a trigger: only a green build publishes one. So "released"
# is the single state that proves the version actually shipped.
release_state() {
  local repo="$1" tag="$2"
  if api_exists "repos/${repo}/releases/tags/${tag}" "release ${tag} in ${repo}"; then
    printf 'released\n'
    return 0
  fi
  # Singular `git/ref/tags/` requires an exact match (404s otherwise). The plural
  # `git/refs/tags/` prefix-matches, so it would report `v0.35.4` as existing when
  # only `v0.35.4-rc.1` had been tagged - a false double-cut on the final release.
  if ! api_exists "repos/${repo}/git/ref/tags/${tag}" "tag ${tag} in ${repo}"; then
    # A missing tag usually does mean nothing has happened yet. It can also mean
    # the tag was deleted - and if a build is STILL RUNNING against that deleted
    # ref, treating this as `absent` would re-create the tag at whatever the
    # branch head is now and dispatch a second build, breaking both invariants at
    # once. Refuse instead: an in-flight build whose ref vanished is a
    # human-caused state that automation must not guess at.
    #
    # Deliberately scoped to runs that have not completed. Run records outlive
    # the tag (they persist for the repo's retention window), so keying on "any
    # run ever" would permanently block the documented re-cut path of deleting
    # the tag and release and starting over.
    if workflow_runs_at_ref "$repo" "$tag" "in_progress" \
      || workflow_runs_at_ref "$repo" "$tag" "queued"; then
      printf 'dispatched-tag-missing\n'
      return 0
    fi
    printf 'absent\n'
    return 0
  fi
  if workflow_runs_at_ref "$repo" "$tag"; then
    printf 'dispatched\n'
  else
    printf 'tagged\n'
  fi
}

# release_state_of <repo> <tag> - sets RELEASE_STATE to release_state's answer.
#
# release_state must run in a command substitution to hand back a value, and an
# `exit` inside one only kills the subshell. Its probes are fail-closed - a
# transient API error is meant to abort the cut rather than read as "nothing
# exists" - so that abort has to be re-raised here or it would be silently
# downgraded to an empty state, which is the exact misreading api_exists exists
# to prevent.
release_state_of() {
  if ! RELEASE_STATE="$(release_state "$1" "$2")"; then
    exit 1
  fi
}

# guard_double_cut <version> <state>... - the one state that is still fatal.
#
# Fatal only when EVERY target repo has a published release, because that is the
# only combination that means "this version already shipped". Anything short of
# it is an interrupted cut, and the ensure_* steps below resume it per repo.
#
# The legacy path is why this counts repos instead of failing on the first
# release it finds: a cut that died between the OSS dispatch and the pro one
# leaves OSS released and pro untagged, which is the single most common partial
# failure and exactly the case an operator needs to be able to finish.
guard_double_cut() {
  local version="$1"
  shift
  local state all_released="true"
  for state in "$@"; do
    if [[ "$state" == "dispatched-tag-missing" ]]; then
      echo "::error::a ${WORKFLOW} run for ${version} is still in flight, but its tag no longer exists. Someone deleted the tag under a running build. Wait for that run to finish (or cancel it) and reconcile the tag before cutting ${version} again - re-tagging now would point ${version} at a different commit than the build that is running." >&2
      exit 1
    fi
    [[ "$state" == "released" ]] || all_released="false"
  done
  if [[ "$all_released" == "true" ]]; then
    echo "::error::release ${version} already exists in every target repo. Refusing to re-cut (double-cut guard). Delete the release(s) and tag(s) to genuinely re-cut, or bump the version." >&2
    exit 1
  fi
}

# announce_state <repo> <tag> <state> - one line per repo so the run log opens
# with what the cut found, before it changes anything.
announce_state() {
  local repo="$1" tag="$2" state="$3"
  case "$state" in
    absent)     echo "::notice::${repo}: ${tag} not started; will tag and dispatch." ;;
    tagged)     echo "::notice::${repo}: ${tag} already tagged but never dispatched; resuming at the dispatch." ;;
    dispatched) echo "::notice::${repo}: ${tag} already tagged and dispatched; nothing left to do here. Inspect: gh run list --repo ${repo} --workflow ${WORKFLOW} --branch ${tag}" ;;
    released)   echo "::notice::${repo}: ${tag} already released; skipping this repo." ;;
    dispatched-tag-missing)
                echo "::notice::${repo}: ${tag} has a run in flight but no tag." ;;
  esac
}

# create_tag <repo> <branch> <tag> - tag the branch head. Inert w.r.t. release
# workflows (they trigger on workflow_dispatch, not tag push).
create_tag() {
  local repo="$1" branch="$2" tag="$3" sha
  if [[ "${DRY_RUN:-true}" == "true" ]]; then
    echo "[dry-run] gh api -X POST repos/${repo}/git/refs -f ref=refs/tags/${tag} -f sha=<${branch} head>"
    return 0
  fi
  # `.object.sha // empty` guards the jq null-string hazard: on an unexpected
  # ref-response shape jq would otherwise print the literal "null" and exit 0
  # (set -e does not catch it), producing a GitHub 422 "Invalid SHA" instead of
  # a meaningful diagnostic.
  sha="$(gh api "repos/${repo}/git/refs/heads/${branch}" --jq '.object.sha // empty')"
  if [[ -z "$sha" ]]; then
    echo "::error::could not resolve HEAD sha for branch '${branch}' in ${repo}" >&2
    exit 1
  fi
  gh api -X POST "repos/${repo}/git/refs" -f ref="refs/tags/${tag}" -f sha="${sha}" >/dev/null
  echo "created tag ${tag} in ${repo} at ${branch} (${sha})"
}

# dispatch <repo> <tag> - run that ref's release.yaml. --ref <tag> executes the
# tagged commit's version of the workflow (verified in sandbox).
dispatch() {
  local repo="$1" tag="$2"
  shift 2
  # Optional trailing args are extra `gh workflow run` flags (e.g.
  # -f triggered_by=<actor>). Callers on legacy paths pass none, so those
  # dispatches are byte-for-byte unchanged.
  local extra=("$@")
  if [[ "${DRY_RUN:-true}" == "true" ]]; then
    echo "[dry-run] gh workflow run ${WORKFLOW} --repo ${repo} --ref ${tag} ${extra[*]}"
    return 0
  fi
  gh workflow run "${WORKFLOW}" --repo "${repo}" --ref "${tag}" "${extra[@]}"
  echo "dispatched ${WORKFLOW} in ${repo} at ${tag}"
}

# ensure_tag <repo> <branch> <tag> <state> - create the tag only when this repo
# has not got one yet. Skipping on a resume is not just an optimisation: the tag
# a previous run created is what its already-dispatched build is building, so
# re-pointing it would change what ships under a version that is already moving.
ensure_tag() {
  local repo="$1" branch="$2" tag="$3" state="$4"
  case "$state" in
    absent) create_tag "$repo" "$branch" "$tag" ;;
    *)      echo "resume: tag ${tag} already exists in ${repo}; not re-tagging" ;;
  esac
}

# ensure_dispatch <repo> <tag> <state> [extra gh flags...] - dispatch this line's
# release.yaml unless a run already exists at the tag.
#
# A run in ANY conclusion counts as dispatched, failed ones included. A failed
# build is re-run from its own workflow, where the operator can see why it broke;
# firing a fresh one from the release button would hide that behind a second run
# of the same tag.
ensure_dispatch() {
  local repo="$1" tag="$2" state="$3"
  shift 3
  case "$state" in
    dispatched)
      echo "resume: ${WORKFLOW} already dispatched at ${tag} in ${repo}; not dispatching again"
      echo "        inspect it with: gh run list --repo ${repo} --workflow ${WORKFLOW} --branch ${tag}"
      ;;
    released)
      echo "resume: ${tag} is already released in ${repo}; not dispatching"
      ;;
    *)
      dispatch "$repo" "$tag" "$@"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

# bump_landed_on_branch <line> <version> - does <line>'s go.mod actually require
# github.com/loft-sh/vcluster at <version>?
#
# A merged bump PR is evidence the bump once landed, not that it is still there.
# A revert or a force-push on the release branch leaves the PR merged while the
# dependency is back where it was, and tagging pro off that branch would ship a
# release built against the wrong OSS code - the worst outcome this action can
# produce. So the merged-PR shortcut is confirmed against branch content before
# it is trusted.
#
# Matches the exact tag or a pseudo-version derived from it. `go get` resolves to
# a pseudo-version (<base>.0.<14-digit timestamp>-<12-hex>) when the tag is not
# yet a resolvable release, which is a normal outcome of a legacy cut - v0.35's
# go.mod carries v0.35.4-rc.1.0.20260827163720-103b53de2b62 for exactly that
# reason. A plain prefix match would be wrong in the dangerous direction: it
# would let a branch still on v0.35.4-rc.1 satisfy a cut of v0.35.4.
#
# Returns 2 (not 1) when the lookup itself fails, so the caller can distinguish
# "definitely not bumped" from "could not tell" and fail closed on both.
bump_landed_on_branch() {
  local line="$1" version="$2" body required
  if ! body="$(gh api "repos/${PRO_REPO}/contents/go.mod?ref=${line}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)"; then
    return 2
  fi
  [[ -n "$body" ]] || return 2
  required="$(printf '%s\n' "$body" | awk '$1 == "github.com/loft-sh/vcluster" { print $2; exit }')"
  [[ -n "$required" ]] || return 2
  BUMP_FOUND_VERSION="$required"
  [[ "$required" =~ ^"${version}"(\.0\.[0-9]{14}-[0-9a-f]{12})?$ ]]
}

# bump_pr_probe <bump_branch> <base> - one read of the bump PR, as "<state>|<merged_at>".
# Prints "none|" when no PR exists yet. Unlike the poll below a single failed
# read is not fatal here: the caller only uses this to decide whether the bump
# workflow still needs dispatching, and re-dispatching is the safe default.
bump_pr_probe() {
  local bump_branch="$1" base="$2" out
  if ! out="$(gh api "repos/${PRO_REPO}/pulls?head=${PRO_OWNER}:${bump_branch}&base=${base}&state=all" \
    --jq "$BUMP_PR_JQ" 2>/dev/null)"; then
    printf 'none|\n'
    return 0
  fi
  [[ -n "$out" ]] || out="none|"
  printf '%s\n' "$out"
}

# bump_pro_dependency <version> <line> - dispatch the pro release-bump workflow
# to open a loft-bot PR bumping the vendored github.com/loft-sh/vcluster
# dependency on the <line> branch to <version>, then block until
# auto-approve-bot-prs merges it. Replaces the manual "release-prep" PR that
# used to precede a legacy cut, so the pro tag created next builds against the
# OSS code being co-released.
#
# Probes the PR before dispatching, because the bump workflow is not idempotent
# from this side: dispatched a second time against a branch that already carries
# the bump it opens nothing (or an empty PR that can never merge), and the wait
# below would then block on a PR that will never move. A resume therefore reuses
# whatever bump already exists:
#   merged -> the dependency is already on the branch; nothing to do
#   open   -> skip the dispatch, just wait for the existing PR to merge
#   closed -> the previous attempt was abandoned; dispatch a fresh one
#   none   -> first time through; dispatch
#
# Honors DRY_RUN: prints what it would do, mutates nothing. The bump branch name
# is the contract shared with the pro release-bump-vcluster.yaml (which creates
# it) and this poll's head= filter. auto-approve-bot-prs enables auto-merge for
# the PR via the vcluster-pro caller's branch-scoped `if:`
# (chore/*/bump-vcluster-*) PLUS the action's own eligibility gate (trusted
# author loft-bot + a chore-prefixed PR *title*) -- the branch match alone is not
# auto-approve's merge lever.
bump_pro_dependency() {
  local version="$1" line="$2"
  local bump_branch="chore/${line}/bump-vcluster-${version}" tuple state merged
  tuple="$(bump_pr_probe "$bump_branch" "$line")"
  state="${tuple%%|*}"
  merged="${tuple#*|}"

  if [[ -n "$merged" ]]; then
    BUMP_FOUND_VERSION=""
    bump_landed_on_branch "$line" "$version"
    case $? in
      0)
        echo "::notice::resume: bump PR ${bump_branch} was already merged into ${line} (${merged}) and go.mod requires ${BUMP_FOUND_VERSION}; skipping the bump dispatch."
        return 0
        ;;
      1)
        echo "::error::bump PR ${bump_branch} is merged (${merged}) but ${PRO_REPO}@${line} go.mod requires github.com/loft-sh/vcluster ${BUMP_FOUND_VERSION}, not ${version}. The bump was reverted or the branch was force-pushed. Refusing to tag pro against an un-bumped go.mod - reconcile ${line} before re-running." >&2
        exit 1
        ;;
      *)
        echo "::error::bump PR ${bump_branch} is merged (${merged}) but ${PRO_REPO}@${line} go.mod could not be read, so the bump cannot be confirmed. Refusing to tag pro against a dependency state we cannot verify." >&2
        exit 1
        ;;
    esac
  fi

  if [[ "$state" == "open" ]]; then
    echo "::notice::resume: bump PR ${bump_branch} is already open; skipping the dispatch and waiting on it."
    if [[ "${DRY_RUN:-true}" == "true" ]]; then
      echo "[dry-run] would wait for PR ${PRO_OWNER}:${bump_branch} -> ${line} to merge, then tag ${PRO_REPO}@${line}"
      return 0
    fi
    wait_for_bump_merge "${bump_branch}" "${line}" "true"
    return 0
  fi

  if [[ "${DRY_RUN:-true}" == "true" ]]; then
    echo "[dry-run] gh workflow run ${BUMP_WORKFLOW} --repo ${PRO_REPO} --ref ${PRO_DEFAULT_BRANCH} -f version=${version} -f branch=${line}"
    echo "[dry-run] would wait for PR ${PRO_OWNER}:${bump_branch} -> ${line} to merge, then tag ${PRO_REPO}@${line}"
    return 0
  fi
  echo "::notice::dispatching ${BUMP_WORKFLOW} to bump ${PRO_REPO}@${line} to ${version}"
  gh workflow run "${BUMP_WORKFLOW}" --repo "${PRO_REPO}" --ref "${PRO_DEFAULT_BRANCH}" \
    -f version="${version}" -f branch="${line}"
  wait_for_bump_merge "${bump_branch}" "${line}"
}

# wait_for_bump_merge <bump_branch> <base> - block until the bump PR (head
# <bump_branch> into <base>) is merged. Fail closed: a closed-unmerged PR or a
# timeout aborts the cut, so pro is never tagged against an un-bumped go.mod. A
# still-absent PR (the dispatched workflow has not opened it yet) is a normal
# early state, so keep polling until it appears.
#
# A "closed" state only aborts once the PR has been seen "open" during THIS
# wait. On the documented re-run recovery a previous closed PR is still the
# newest ?state=all match for the ~1-2 min until the fresh workflow opens a new
# one; without this guard the first poll would abort every re-run. Sustained
# API failures (bad token/repo, not a transient blip) also abort, so a real
# auth error surfaces with its own cause instead of the generic timeout.
wait_for_bump_merge() {
  local bump_branch="$1" base="$2" i out rc tuple state merged
  # A resume that already observed the PR open passes seen_open=true, so a PR
  # that closes unmerged from here aborts immediately instead of being read as
  # the "stale closed PR from a previous attempt" case and waiting out the full
  # timeout. Losing that observation is the difference between failing in
  # seconds and failing in two hours.
  local seen_open="${3:-false}" fails=0
  for (( i = 1; i <= BUMP_WAIT_ATTEMPTS; i++ )); do
    rc=0
    out="$(gh api "repos/${PRO_REPO}/pulls?head=${PRO_OWNER}:${bump_branch}&base=${base}&state=all" \
      --jq "$BUMP_PR_JQ" 2>&1)" || rc=$?
    if (( rc != 0 )); then
      fails=$(( fails + 1 ))
      echo "::warning::bump-merge poll attempt ${i}: GitHub API call failed (${fails}/${BUMP_WAIT_MAX_API_FAILURES}): $(printf '%s' "$out" | tr '\n' ' ')"
      if (( fails >= BUMP_WAIT_MAX_API_FAILURES )); then
        echo "::error::${BUMP_WAIT_MAX_API_FAILURES} consecutive GitHub API failures polling ${PRO_REPO} pulls (head=${PRO_OWNER}:${bump_branch}); check the token scopes and repo, not the bump workflow." >&2
        exit 1
      fi
      sleep "${BUMP_WAIT_SLEEP_SECONDS}"
      continue
    fi
    fails=0
    tuple="$out"
    state="${tuple%%|*}"
    merged="${tuple#*|}"
    if [[ -n "$merged" ]]; then
      echo "::notice::bump PR ${bump_branch} merged into ${base} (${merged})."
      return 0
    fi
    [[ "$state" == "open" ]] && seen_open="true"
    if [[ "$state" == "closed" && "$seen_open" == "true" ]]; then
      echo "::error::bump PR ${bump_branch} was closed without merging; aborting the cut so pro is not tagged against an un-bumped go.mod." >&2
      exit 1
    fi
    # Periodic heartbeat so an operator watching a stuck cut can tell a healthy
    # poll from a silent hang.
    if (( i % 12 == 0 )); then
      echo "::notice::bump-merge poll: attempt ${i}/${BUMP_WAIT_ATTEMPTS} (~$(( i * BUMP_WAIT_SLEEP_SECONDS / 60 )) min), PR state=${state}, still waiting for merge."
    fi
    sleep "${BUMP_WAIT_SLEEP_SECONDS}"
  done
  echo "::error::timed out after $(( BUMP_WAIT_ATTEMPTS * BUMP_WAIT_SLEEP_SECONDS ))s waiting for bump PR ${bump_branch} -> ${base} to merge. Inspect the ${BUMP_WORKFLOW} run and auto-approve-bot-prs on ${PRO_REPO}, then recover per the README." >&2
  exit 1
}

cut_legacy() {
  local version="$1" line="$2" oss_state pro_state
  echo "Routing ${version} -> legacy (line ${line}); dispatch order: ${OSS_REPO} then ${PRO_REPO}"
  # Both repos must be ready before we mutate anything.
  require_branch "$OSS_REPO" "$line"
  require_branch "$PRO_REPO" "$line"
  # Read how far a previous cut got in each repo BEFORE touching either, so the
  # log opens with the full picture and every step below can be skipped on its
  # own. Re-running the button is the documented way to finish an interrupted
  # cut; only an all-released version is refused.
  release_state_of "$OSS_REPO" "$version"; oss_state="$RELEASE_STATE"
  release_state_of "$PRO_REPO" "$version"; pro_state="$RELEASE_STATE"
  guard_double_cut "$version" "$oss_state" "$pro_state"
  announce_state "$OSS_REPO" "$version" "$oss_state"
  announce_state "$PRO_REPO" "$version" "$pro_state"
  # Tag OSS first so `go get github.com/loft-sh/vcluster@${version}` resolves the
  # freshly cut tag during the pro dependency bump below.
  ensure_tag "$OSS_REPO" "$line" "$version" "$oss_state"
  # Bump the vendored OSS dependency on the pro release branch to the tag just
  # created and wait for the auto-merged PR to land, so the pro tag/build below
  # ships the OSS code being co-released. Automates the old manual release-prep PR.
  # Skipped entirely once pro has moved past tagging: the bump is upstream of the
  # pro tag, so a tagged/dispatched/released pro already has it.
  if [[ "$pro_state" == "absent" ]]; then
    bump_pro_dependency "$version" "$line"
  else
    echo "::notice::resume: ${PRO_REPO} is already at '${pro_state}' for ${version}; the dependency bump already landed, skipping it."
  fi
  # Tag pro at the now-bumped branch head. Both tags still precede either
  # dispatch, preserving the tag-before-dispatch invariant.
  ensure_tag "$PRO_REPO" "$line" "$version" "$pro_state"
  ensure_dispatch "$OSS_REPO" "$version" "$oss_state"
  # OSS is now building. This sequence is non-atomic, but it is resumable: if the
  # pro dispatch below fails, re-run this action with the same version. It reads
  # the state back, sees OSS dispatched, and picks up at the pro dispatch alone.
  if [[ "${DRY_RUN:-true}" != "true" ]]; then
    echo "::notice::${OSS_REPO} dispatched for ${version}. If the ${PRO_REPO} dispatch below fails, just re-run this action with the same version - it resumes and will not re-dispatch ${OSS_REPO}."
  fi
  ensure_dispatch "$PRO_REPO" "$version" "$pro_state"
}

cut_monorepo() {
  local version="$1" target="$2" state
  echo "Routing ${version} -> monorepo (target ${target}); dispatch: ${PRO_REPO} only"
  # The target is resolved from the suffix matrix, so it must already exist:
  # stable/rc name a vX.Y branch that has to be cut first, alpha/beta name main.
  # Refusing to guess is the point - never fall back to a different branch.
  require_branch "$PRO_REPO" "$target"
  release_state_of "$PRO_REPO" "$version"; state="$RELEASE_STATE"
  guard_double_cut "$version" "$state"
  announce_state "$PRO_REPO" "$version" "$state"
  ensure_tag "$PRO_REPO" "$target" "$version" "$state"
  local dispatch_args=()
  [[ -n "${TRIGGERED_BY}" ]] && dispatch_args=(-f "triggered_by=${TRIGGERED_BY}")
  ensure_dispatch "$PRO_REPO" "$version" "$state" "${dispatch_args[@]}"
}

# cut_feature_prerelease <version> <feature-branch> - -next / -next.internal are
# cut from a short-lived feature branch and only ever build pro (they are
# prereleases of a future, monorepo-era line). Bypasses the era fan-out.
cut_feature_prerelease() {
  local version="$1" feature="$2" state
  echo "Routing ${version} -> feature-branch prerelease (source ${feature}); dispatch: ${PRO_REPO} only"
  require_branch "$PRO_REPO" "$feature"
  release_state_of "$PRO_REPO" "$version"; state="$RELEASE_STATE"
  guard_double_cut "$version" "$state"
  announce_state "$PRO_REPO" "$version" "$state"
  ensure_tag "$PRO_REPO" "$feature" "$version" "$state"
  local dispatch_args=()
  [[ -n "${TRIGGERED_BY}" ]] && dispatch_args=(-f "triggered_by=${TRIGGERED_BY}")
  ensure_dispatch "$PRO_REPO" "$version" "$state" "${dispatch_args[@]}"
}

main() {
  local raw_version="${INPUT_VERSION:?INPUT_VERSION is required}" version era line raw_dry_run
  # Canonicalize before ANY consumer sees it: the tag name, the double-cut probe
  # and every routing decision must all agree on one spelling. Echo the rewrite
  # so the run log shows exactly which tag is about to be created.
  version="$(normalize_version "$raw_version")"
  if [[ "$version" != "$raw_version" ]]; then
    echo "::notice::normalized version '${raw_version}' -> '${version}'"
  fi
  # Gate on the canonical value, before any branch is read or tag created. This
  # is the single validation point for EVERY release line: legacy cuts fan out
  # from here too, so their branch-local release.yaml never sees a malformed
  # version even though it carries no gate of its own.
  validate_version "$version" || exit 1
  # Fail closed: only an explicit, unambiguous "false" cuts for real. Any other
  # value (empty, typo, "yes", "1", wrong case, stray whitespace) stays in
  # dry-run, so a misconfigured caller can never accidentally fire a real
  # cross-repo release.
  raw_dry_run="${INPUT_DRY_RUN:-true}"
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
  source_branch="${INPUT_SOURCE_BRANCH:-}"
  line="$(derive_line "$version")"
  echo "vcluster-release: version=${version} suffix=${suffix} source-branch=${source_branch:-<none>} dry_run=${DRY_RUN} cutover=${CUTOVER}"

  # Feature-branch prereleases (-next/-next.internal) short-circuit the era
  # routing: they are cut from a short-lived feature branch and always build pro.
  if [[ "$suffix" == "next" || "$suffix" == "next-internal" ]]; then
    if [[ -z "$source_branch" ]]; then
      echo "::error::${suffix} releases require the source-branch input (the short-lived feature branch to cut from)." >&2
      exit 1
    fi
    if ! is_feature_branch "$source_branch"; then
      echo "::error::${suffix} releases are cut from a short-lived feature branch, not '${source_branch}' (main and vX.Y release branches are not allowed)." >&2
      exit 1
    fi
    cut_feature_prerelease "$version" "$source_branch"
    return
  fi

  era="$(classify_era "$version")"

  case "$era" in
    monorepo)
      target="$(resolve_target "$suffix" "$source_branch" "$line")" || exit 1
      cut_monorepo "$version" "$target" ;;
    legacy)
      # Legacy lines are historical two-repo lines: only rc/stable are cut, from
      # the vX.Y branch. main-sourced (alpha/beta) and feature-sourced (next)
      # prereleases are go-forward concepts that do not apply here.
      case "$suffix" in
        rc|stable) ;;
        *) echo "::error::${suffix} releases are not supported on the legacy line ${line}; legacy lines cut only rc or stable from the ${line} branch." >&2; exit 1 ;;
      esac
      if [[ -n "$source_branch" && "$source_branch" != "$line" ]]; then
        echo "::error::legacy ${line} releases are cut from the ${line} branch, not '${source_branch}'." >&2
        exit 1
      fi
      cut_legacy "$version" "$line" ;;
    *)
      echo "::error::unknown era '${era}'" >&2; exit 1 ;;
  esac
}

# Only auto-run when executed directly; sourcing (e.g. from bats) must not.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

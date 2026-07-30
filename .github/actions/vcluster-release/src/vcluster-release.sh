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
# AND sail past guard_not_released, which probes for "v0.37.1" and gets a 404.
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

# guard_not_released <repo> <tag> - double-cut guard. A pre-existing tag or
# release for this version is a hard error: releases are cut once.
guard_not_released() {
  local repo="$1" tag="$2"
  # Both probes go through api_exists, so a transient API failure (rate-limit /
  # auth / DNS) aborts loudly instead of being misread as "not released" - which
  # would silently skip the double-cut guard.
  if api_exists "repos/${repo}/releases/tags/${tag}" "release ${tag} in ${repo}"; then
    echo "::error::release ${tag} already exists in ${repo}. Refusing to re-cut (double-cut guard)." >&2
    exit 1
  fi
  # Singular `git/ref/tags/` requires an exact match (404s otherwise). The plural
  # `git/refs/tags/` prefix-matches, so it would report `v0.35.4` as existing when
  # only `v0.35.4-rc.1` had been tagged - a false double-cut on the final release.
  if api_exists "repos/${repo}/git/ref/tags/${tag}" "tag ${tag} in ${repo}"; then
    echo "::error::tag ${tag} already exists in ${repo}. Delete it to re-cut, or bump the version." >&2
    exit 1
  fi
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

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

# bump_pro_dependency <version> <line> - dispatch the pro release-bump workflow
# to open a loft-bot PR bumping the vendored github.com/loft-sh/vcluster
# dependency on the <line> branch to <version>, then block until
# auto-approve-bot-prs merges it. Replaces the manual "release-prep" PR that
# used to precede a legacy cut, so the pro tag created next builds against the
# OSS code being co-released.
#
# Honors DRY_RUN: prints the dispatch and the PR it would wait on, mutates
# nothing. The bump branch name is the contract shared with the pro
# release-bump-vcluster.yaml (which creates it) and this poll's head= filter.
# auto-approve-bot-prs enables auto-merge for the PR via the vcluster-pro
# caller's branch-scoped `if:` (chore/*/bump-vcluster-*) PLUS the action's own
# eligibility gate (trusted author loft-bot + a chore-prefixed PR *title*) --
# the branch match alone is not auto-approve's merge lever.
bump_pro_dependency() {
  local version="$1" line="$2"
  local bump_branch="chore/${line}/bump-vcluster-${version}"
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
  local seen_open="false" fails=0
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
  local version="$1" line="$2"
  echo "Routing ${version} -> legacy (line ${line}); dispatch order: ${OSS_REPO} then ${PRO_REPO}"
  # Both repos must be ready before we mutate anything.
  require_branch "$OSS_REPO" "$line"
  require_branch "$PRO_REPO" "$line"
  guard_not_released "$OSS_REPO" "$version"
  guard_not_released "$PRO_REPO" "$version"
  # Tag OSS first so `go get github.com/loft-sh/vcluster@${version}` resolves the
  # freshly cut tag during the pro dependency bump below.
  create_tag "$OSS_REPO" "$line" "$version"
  # Bump the vendored OSS dependency on the pro release branch to the tag just
  # created and wait for the auto-merged PR to land, so the pro tag/build below
  # ships the OSS code being co-released. Automates the old manual release-prep PR.
  bump_pro_dependency "$version" "$line"
  # Tag pro at the now-bumped branch head. Both tags still precede either
  # dispatch, preserving the tag-before-dispatch invariant.
  create_tag "$PRO_REPO" "$line" "$version"
  dispatch "$OSS_REPO" "$version"
  # OSS is now building. This sequence is non-atomic: if the pro dispatch below
  # fails, the correct recovery is to dispatch pro ONLY. Deleting the tags and
  # re-running this action would re-dispatch (and rebuild) OSS and re-open the
  # bump PR. Emit the true progress state so a partial failure is diagnosable
  # from the run log rather than misread as a plain double-cut. See README >
  # Partial-failure recovery.
  if [[ "${DRY_RUN:-true}" != "true" ]]; then
    echo "::notice::${OSS_REPO} dispatched for ${version}. If the ${PRO_REPO} dispatch below fails, recover by dispatching ${PRO_REPO} only - do NOT delete tags and re-run this action (that re-dispatches OSS)."
  fi
  dispatch "$PRO_REPO" "$version"
}

cut_monorepo() {
  local version="$1" target="$2"
  echo "Routing ${version} -> monorepo (target ${target}); dispatch: ${PRO_REPO} only"
  # The target is resolved from the suffix matrix, so it must already exist:
  # stable/rc name a vX.Y branch that has to be cut first, alpha/beta name main.
  # Refusing to guess is the point - never fall back to a different branch.
  require_branch "$PRO_REPO" "$target"
  guard_not_released "$PRO_REPO" "$version"
  create_tag "$PRO_REPO" "$target" "$version"
  local dispatch_args=()
  [[ -n "${TRIGGERED_BY}" ]] && dispatch_args=(-f "triggered_by=${TRIGGERED_BY}")
  dispatch "$PRO_REPO" "$version" "${dispatch_args[@]}"
}

# cut_feature_prerelease <version> <feature-branch> - -next / -next.internal are
# cut from a short-lived feature branch and only ever build pro (they are
# prereleases of a future, monorepo-era line). Bypasses the era fan-out.
cut_feature_prerelease() {
  local version="$1" feature="$2"
  echo "Routing ${version} -> feature-branch prerelease (source ${feature}); dispatch: ${PRO_REPO} only"
  require_branch "$PRO_REPO" "$feature"
  guard_not_released "$PRO_REPO" "$version"
  create_tag "$PRO_REPO" "$feature" "$version"
  local dispatch_args=()
  [[ -n "${TRIGGERED_BY}" ]] && dispatch_args=(-f "triggered_by=${TRIGGERED_BY}")
  dispatch "$PRO_REPO" "$version" "${dispatch_args[@]}"
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

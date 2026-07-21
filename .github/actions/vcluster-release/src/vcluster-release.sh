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
# The human who invoked cut-release. Forwarded to the monorepo-era release.yaml
# (-f triggered_by=...) so the Slack banner attributes the person, not the bot
# PAT that dispatches the build. Only passed on paths whose release.yaml declares
# the input (monorepo + feature-prerelease); legacy release.yaml's don't have it,
# and gh workflow run rejects undeclared inputs, so legacy dispatches omit it.
TRIGGERED_BY="${TRIGGERED_BY:-}"

# ---------------------------------------------------------------------------
# Pure helpers (no network) - the routing brain, exhaustively unit-tested.
# ---------------------------------------------------------------------------

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

cut_legacy() {
  local version="$1" line="$2"
  echo "Routing ${version} -> legacy (line ${line}); dispatch order: ${OSS_REPO} then ${PRO_REPO}"
  # Both repos must be ready before we mutate anything.
  require_branch "$OSS_REPO" "$line"
  require_branch "$PRO_REPO" "$line"
  guard_not_released "$OSS_REPO" "$version"
  guard_not_released "$PRO_REPO" "$version"
  # Tag both, then dispatch OSS first so the OSS release exists for pro's
  # standalone upload (pro's builder still waits/retries for it).
  create_tag "$OSS_REPO" "$line" "$version"
  create_tag "$PRO_REPO" "$line" "$version"
  dispatch "$OSS_REPO" "$version"
  # OSS is now building. This sequence is non-atomic: if the pro dispatch below
  # fails, the correct recovery is to dispatch pro ONLY. Deleting the tags and
  # re-running this action would re-dispatch (and rebuild) OSS. Emit the true
  # progress state so a partial failure is diagnosable from the run log rather
  # than misread as a plain double-cut. See README > Partial-failure recovery.
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
  local version="${INPUT_VERSION:?INPUT_VERSION is required}" era line raw_dry_run
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

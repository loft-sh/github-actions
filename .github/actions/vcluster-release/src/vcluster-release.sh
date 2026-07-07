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
# Routing by numeric (major, minor) compare against CUTOVER (v0.36):
#   legacy   (< v0.36) -> verify the vX.Y branch in BOTH repos, tag both, then
#                         dispatch loft-sh/vcluster FIRST, then loft-sh/vcluster-pro.
#   monorepo (>= v0.36) -> resolve target (line branch vX.Y if it exists, else
#                         main), tag it, dispatch loft-sh/vcluster-pro only.
#
# dry_run (default true) performs the read-only checks (branch existence,
# double-cut guard) so the printed routing decision is validated, but prints the
# mutating tag/dispatch calls instead of firing them.
set -euo pipefail

CUTOVER="${CUTOVER:-v0.36}"
OSS_REPO="${OSS_REPO:-loft-sh/vcluster}"
PRO_REPO="${PRO_REPO:-loft-sh/vcluster-pro}"
WORKFLOW="${WORKFLOW:-release.yaml}"

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

# ---------------------------------------------------------------------------
# Network helpers. Read-only ones always run (they validate the routing, even
# in dry-run). Mutating ones honour DRY_RUN.
# ---------------------------------------------------------------------------

# branch_exists <repo> <branch> -> 0 if 200, 1 if 404, exits 1 on transient error.
# Read only the HTTP status line. On a 404 `gh` exits non-zero, so we must
# capture its output with `|| true` BEFORE parsing - piping gh directly into the
# status-substitution would let pipefail propagate the non-zero exit and clobber
# the code to empty, misreading a real 404 as a transient failure. gh writes the
# "HTTP/2.0 404" status line to stdout even with --silent (only the body is
# suppressed); a genuine transient error (DNS/auth/rate-limit) yields no status
# line, so an empty code correctly means "could not reach the API".
branch_exists() {
  local repo="$1" branch="$2" headers http_code
  headers="$(gh api "repos/${repo}/branches/${branch}" --silent -i 2>/dev/null || true)"
  http_code="$(printf '%s\n' "$headers" | head -1 | awk '{print $2}')"
  case "$http_code" in
    200) return 0 ;;
    404) return 1 ;;
    "")
      echo "::error::failed to reach ${repo} branches API for '${branch}' (no HTTP status - DNS, rate-limit, or auth). Not treating as missing." >&2
      exit 1
      ;;
    *)
      echo "::error::unexpected status ${http_code} from ${repo} branches API for '${branch}'." >&2
      exit 1
      ;;
  esac
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
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "::error::release ${tag} already exists in ${repo}. Refusing to re-cut (double-cut guard)." >&2
    exit 1
  fi
  if gh api "repos/${repo}/git/refs/tags/${tag}" >/dev/null 2>&1; then
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
  if [[ "${DRY_RUN:-true}" == "true" ]]; then
    echo "[dry-run] gh workflow run ${WORKFLOW} --repo ${repo} --ref ${tag}"
    return 0
  fi
  gh workflow run "${WORKFLOW}" --repo "${repo}" --ref "${tag}"
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
  local version="$1" line="$2" target
  if branch_exists "$PRO_REPO" "$line"; then
    target="$line"
  else
    target="main"
  fi
  echo "Routing ${version} -> monorepo (line ${line}, target ${target}); dispatch: ${PRO_REPO} only"
  guard_not_released "$PRO_REPO" "$version"
  create_tag "$PRO_REPO" "$target" "$version"
  dispatch "$PRO_REPO" "$version"
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
  echo "vcluster-release: version=${version} dry_run=${DRY_RUN} cutover=${CUTOVER}"

  era="$(classify_era "$version")"
  line="$(derive_line "$version")"

  case "$era" in
    legacy)   cut_legacy "$version" "$line" ;;
    monorepo) cut_monorepo "$version" "$line" ;;
    *)        echo "::error::unknown era '${era}'" >&2; exit 1 ;;
  esac
}

# Only auto-run when executed directly; sourcing (e.g. from bats) must not.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

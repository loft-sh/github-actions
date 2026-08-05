#!/usr/bin/env bash
# Promote a just-published stable release: retag docker moving tags onto the
# version's already-published, already-signed manifest (a digest-preserving
# retag via `crane tag`, never a rebuild -- cosign signatures are
# digest-scoped OCI referrers, so the copy stays verifiable with no
# re-signing), and optionally flip the caller's own release and a paired
# public release off pre-release + onto latest.
#
# `crane tag`, not `docker buildx imagetools create`: imagetools is
# digest-preserving only when the source is already a multi-arch index. For a
# bare single-platform manifest (a per-arch tag like :vX.Y.Z-amd64) it wraps
# the manifest in a NEW index, changing the digest and orphaning the
# digest-scoped cosign signature. `crane tag` re-points a tag at the exact
# same manifest digest for both single-platform manifests and indexes, so it
# covers the whole moving-tag matrix -- including the per-arch tags -- without
# breaking signatures. (Verified live, DEVOPS-1083.)
#
# Only acts on a stable vX.Y.Z version; any other shape (has a "-" suffix) is
# a no-op, since moving tags and "latest" promotion aren't meaningful for
# -rc/-alpha/-next cuts.
#
# Required env:
#   GH_TOKEN        Token with GHCR write:packages; contents:write on the
#                    caller's GITHUB_REPOSITORY when INPUT_PROMOTE_SELF=true;
#                    and contents:write on INPUT_OSS_REPO and
#                    INPUT_HOMEBREW_TAP_REPO if set. Docker login happens in
#                    the calling action.yml step, before this script runs.
#   INPUT_VERSION    The promoted release tag, e.g. v0.37.1.
#   INPUT_IMAGES     JSON array of image entries to retag, each
#                    {"image": "ghcr.io/loft-sh/x", "suffix": ""} (suffix
#                    optional, default ""). For each entry, copies
#                    <image>:<version><suffix> to <image>:latest<suffix>,
#                    <image>:<major><suffix>, and <image>:<major>.<minor><suffix>.
#
# Optional env:
#   INPUT_PROMOTE_SELF
#                    "true" also promotes the CALLER repo's own <version>
#                     release (unset pre-release, set Latest). Needed when the
#                     caller publishes stable cuts with the GitHub "None"
#                     label, where nothing else ever flips them. Any other
#                     value (default "false") leaves that release untouched.
#   INPUT_OSS_REPO   owner/repo whose matching <version> release should also
#                     be promoted. Empty (default) skips this step. Required
#                     if INPUT_HOMEBREW_TAP_REPO is set (checksums for the
#                     tap come from this repo's <version> release).
#   INPUT_HOMEBREW_TAP_REPO
#                    owner/repo of a Homebrew tap to promote (e.g.
#                     loft-sh/homebrew-tap). Empty (default) skips this step.
#   INPUT_HOMEBREW_FORMULA_PATHS
#                    JSON array of formula file paths within
#                     INPUT_HOMEBREW_TAP_REPO to update, e.g.
#                     ["Formula/vcluster.rb"]. Required if
#                     INPUT_HOMEBREW_TAP_REPO is set.
#   INPUT_DRY_RUN    Fail-closed: a real promotion runs only on an exact
#                     (case-insensitive) "false" - which is the default, so a
#                     plain dispatch still promotes for real. ANY
#                     other value ("true", "yes", "1", a typo, wrong case,
#                     stray whitespace) is a dry-run that only prints the
#                     planned retags/promotion, so a caller who meant to
#                     preview can't accidentally fire a real retag/release flip.
#
# GITHUB_REPOSITORY (owner/repo of the caller, set automatically by Actions)
# is used to detect a backport/patch promotion: if VERSION is older than the
# release currently flagged Latest on that repo, :latest/:{major} are left
# alone so promoting an older line's patch can never move :latest backwards. :{major}.{minor} is
# scoped to VERSION's own line, so it advances on its own gate: only when
# VERSION is the newest stable *within its own {major}.{minor} line*. That
# keeps a same-line out-of-order promotion (e.g. promoting v9.9.5 after
# v9.9.6 already moved :9.9) from regressing the line tag too.
#
# Homebrew promotion is a metadata patch, not a rebuild: a formula's per-
# platform sha256 values are exactly what's already in oss-repo's <version>
# release checksums.txt (already published, already cosign-signed), so
# there's nothing to re-hash. Only the version line and each url/sha256
# pair are rewritten in place - everything else in the formula (deps,
# install blocks, test block) is preserved byte-for-byte, so the patch can't
# drift from whatever template shape generated the file.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${INPUT_VERSION:?version required}"
: "${INPUT_IMAGES:?images required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required (set automatically by GitHub Actions)}"

VERSION="${INPUT_VERSION}"
OSS_REPO="${INPUT_OSS_REPO-}"
# Enabling a mutation, so only an exact "true" turns it on: a typo leaves the
# caller's own release untouched rather than flipping it unasked.
PROMOTE_SELF="${INPUT_PROMOTE_SELF:-false}"
if [[ -n "${GITHUB_OUTPUT-}" ]]; then
  PROMOTE_SELF_ENABLED=false
  if [[ "${PROMOTE_SELF}" == "true" ]]; then
    PROMOTE_SELF_ENABLED=true
  fi
  printf 'promote-self-enabled=%s\n' "${PROMOTE_SELF_ENABLED}" >> "${GITHUB_OUTPUT}"
fi
HOMEBREW_TAP_REPO="${INPUT_HOMEBREW_TAP_REPO-}"
HOMEBREW_FORMULA_PATHS="${INPUT_HOMEBREW_FORMULA_PATHS:-[]}"
# Fail closed: real mutations run only on an explicit, unambiguous "false"
# (the input default, so a plain dispatch still promotes for real). Any
# other value - "true", "yes", "1", a typo, wrong case, stray whitespace -
# stays in dry-run, so a caller who meant to preview can never accidentally
# fire a real GHCR retag or release flip. Mirrors the sibling vcluster-release
# action's dry-run contract.
raw_dry_run="${INPUT_DRY_RUN:-false}"
case "${raw_dry_run,,}" in
  false) DRY_RUN="false" ;;
  true)  DRY_RUN="true" ;;
  *)
    echo "::warning::unrecognized dry-run value '${raw_dry_run}'; defaulting to dry-run (no mutations). Pass exactly 'false' to promote for real." >&2
    DRY_RUN="true"
    ;;
esac

if [[ -n "${HOMEBREW_TAP_REPO}" ]]; then
  if [[ -z "${OSS_REPO}" ]]; then
    echo "::error::homebrew-tap-repo requires oss-repo to be set (checksums come from oss-repo's release)" >&2
    exit 1
  fi
  if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"${HOMEBREW_FORMULA_PATHS}"; then
    echo "::error::homebrew-formula-paths must be a non-empty JSON array when homebrew-tap-repo is set, got: ${HOMEBREW_FORMULA_PATHS}" >&2
    exit 1
  fi
fi

if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"${INPUT_IMAGES}"; then
  echo "::error::images must be a non-empty JSON array, got: ${INPUT_IMAGES}" >&2
  exit 1
fi

if [[ ! "${VERSION}" =~ ^v([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
  echo "::notice::${VERSION} is not a stable vX.Y.Z release; moving tags and latest promotion only apply to stable cuts. Nothing to do."
  exit 0
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# Fetches the release list once for a repository. Callers then pass the same
# snapshot to the two predicates below, so the overall and line-scoped gates
# cannot observe different repository states during one promotion.
#
# A failure to LIST releases is never treated as "no prior releases": that
# would fail open on exactly the downgrade these checks exist to prevent.
# "hard" exits before any mutations; "soft" returns 2 after the Docker retags
# have already completed, allowing the advisory paired-release edit to continue
# without --latest.
RELEASE_LIST=""
fetch_release_list() {
  local repo="$1" failure_mode="${2:-hard}" raw

  if raw=$(gh release list --repo "${repo}" --json tagName,isLatest --limit 1000 2>&1); then
    if jq -e '
      type == "array" and
      all(.[];
        (.tagName | type) == "string" and
        (.isLatest == null or (.isLatest | type) == "boolean")
      )
    ' >/dev/null 2>&1 <<<"${raw}"; then
      RELEASE_LIST="${raw}"
      return 0
    fi
    raw="unexpected release-list response: ${raw}"
  fi

  if [[ "${failure_mode}" == "soft" ]]; then
    echo "::warning::failed to list releases on ${repo} to confirm ${VERSION} is promotable (${raw}); skipping the advisory --latest promotion. Docker retags already completed; set latest manually if appropriate." >&2
    RELEASE_LIST=""
    return 2
  fi

  echo "::error::failed to list releases on ${repo} to check backport/patch ordering: ${raw}" >&2
  exit 1
}

# True if VERSION is at or after the GitHub Latest pointer in $1, using the
# release-list JSON snapshot in $2. This gates :latest, :{major}, and the
# repository's GitHub Latest pointer.
#
# The baseline is the release currently flagged isLatest: the last release a
# human actually promoted. It cannot be "newest non-prerelease", because with
# release.prerelease:auto an un-promoted stable cut already has isPrerelease
# false. Equality passes so a partially failed promotion is re-runnable.
#
# If the mutable Latest flag is absent, fall back conservatively to the newest
# stable-shaped tag. A build re-run can clear that flag by re-applying
# make_latest:false, so absence must not be mistaken for a first promotion.
LATEST_BASELINE_NOTE=""
version_at_or_after() {
  local baseline="$1"
  [ -z "${baseline}" ] && return 0
  [ "$(printf '%s\n%s\n' "${VERSION}" "${baseline}" | sort -V | tail -1)" = "${VERSION}" ]
}

is_at_or_after_latest_pointer() {
  local repo="$1" releases="$2" max
  local stable_shape='^v[0-9]+\.[0-9]+\.[0-9]+$'

  # Whatever GitHub flags Latest is the baseline, even when its tag is not a
  # stable release shape. Sorting also makes a corrupt multi-Latest response
  # conservative and deterministic by selecting the newest flagged tag.
  max=$(jq -r '[.[] | select(.isLatest) | .tagName][]' <<<"${releases}" | sort -V | tail -1)
  if [[ -z "${max}" ]]; then
    max=$(jq -r '.[].tagName' <<<"${releases}" \
      | grep -E "${stable_shape}" \
      | sort -V \
      | tail -1) || true
    if [[ -n "${max}" ]]; then
      LATEST_BASELINE_NOTE="newest stable tag ${max}; no release currently flagged Latest"
      echo "::notice::no release on ${repo} carries the Latest flag; using the newest stable tag (${max}) as the conservative promotion baseline. This is expected after a release-build re-run; promote the version that should be Latest to restore the pointer."
    else
      LATEST_BASELINE_NOTE="no prior stable release"
    fi
  else
    LATEST_BASELINE_NOTE="Latest-flagged release ${max}"
  fi

  version_at_or_after "${max}"
}

# True if VERSION is the newest stable-shaped tag in its own major.minor line,
# using the release-list JSON snapshot in $2. GitHub has no per-line Latest
# pointer, so this deliberately ignores mutable isPrerelease state. A stable
# tag may carry that flag after a legacy build re-run; filtering on it could
# hide a newer sibling and allow the line tag to move backwards.
is_newest_in_line() {
  local line="$1" releases="$2" filter max
  filter="^v${line//./\\.}\.[0-9]+$"
  max=$(jq -r '.[].tagName' <<<"${releases}" \
    | grep -E "${filter}" \
    | sort -V \
    | tail -1) || true

  version_at_or_after "${max}"
}

# The 1000-release window is intentionally much larger than the repository's
# lifetime count. An empty line-scoped result means "first release in line", so
# truncating older siblings out of the window would otherwise fail open.
fetch_release_list "${GITHUB_REPOSITORY}" "hard"
CALLER_RELEASE_LIST="${RELEASE_LIST}"

ADVANCE_LATEST_MAJOR=true
if ! is_at_or_after_latest_pointer "${GITHUB_REPOSITORY}" "${CALLER_RELEASE_LIST}"; then
  ADVANCE_LATEST_MAJOR=false
  echo "::notice::${VERSION} is older than the promotion baseline on ${GITHUB_REPOSITORY} (${LATEST_BASELINE_NOTE}); skipping :latest/:${MAJOR} so they aren't moved backwards."
fi
CALLER_BASELINE_NOTE="${LATEST_BASELINE_NOTE}"

# :{major}.{minor} gets its own, line-scoped gate. When VERSION is newest
# overall this is necessarily also true, so the happy path is unchanged; the
# case it guards is a same-line out-of-order promotion where VERSION is NOT
# the newest patch in its own {major}.{minor} line - advancing :{major}.{minor}
# there would silently regress it to an older patch.
ADVANCE_MINOR=true
if ! is_newest_in_line "${MAJOR}.${MINOR}" "${CALLER_RELEASE_LIST}"; then
  ADVANCE_MINOR=false
  echo "::notice::${VERSION} is not the newest stable release in the ${MAJOR}.${MINOR} line on ${GITHUB_REPOSITORY}; skipping :${MAJOR}.${MINOR} so it isn't moved backwards within its own line."
fi

# Validate every entry - and that its source manifest actually exists at
# VERSION - before making any changes, so a config typo or a suffix variant
# (e.g. -fips) that wasn't built for this version can't leave earlier
# entries retagged while a later one fails. Skipped under dry-run, since
# nothing has been pushed to inspect yet in a rehearsal.
IMAGE_COUNT=$(jq -r 'length' <<<"${INPUT_IMAGES}")
for ((i = 0; i < IMAGE_COUNT; i++)); do
  entry=$(jq -c ".[$i]" <<<"${INPUT_IMAGES}")
  image=$(jq -r '.image // empty' <<<"${entry}")
  suffix=$(jq -r '.suffix // ""' <<<"${entry}")
  if [[ -z "${image}" ]]; then
    echo "::error::images[$i] is missing required \"image\" field: ${entry}" >&2
    exit 1
  fi
  if [[ "${DRY_RUN}" != "true" ]] && ! crane digest "${image}:${VERSION}${suffix}" >/dev/null 2>&1; then
    echo "::error::source manifest ${image}:${VERSION}${suffix} does not exist; refusing to start retagging" >&2
    exit 1
  fi
done

# Promotes VERSION on a GitHub repository using an already-decided Latest
# gate. This is shared by the caller's own release and the paired OSS release,
# keeping lookup classification, edit arguments, and repair instructions in one
# place.
#
# $3 controls edit failure: "required" aborts before moving tags because the
# caller's Latest pointer is this action's future downgrade baseline;
# "advisory" warns and continues. $4 allows a dry-run for the caller repo to
# print its planned edit even before the release exists. $5 adds call-site
# context to advisory edit failures (for example, whether retags are complete).
# $6 explains why --latest was withheld.
#
# Return codes: 0 = edit succeeded/planned, 3 = release not found,
# 4 = lookup failed for another reason, 5 = advisory edit failed.
promote_gh_release() {
  local repo="$1" advance_latest="$2" failure_mode="$3" preview_missing="${4:-false}"
  local prior_note="${5:-}" skip_reason="${6:-the promotion ordering gate withheld it}"
  local view_output lookup_rc=0 latest_note=""
  local -a edit_args=(--prerelease=false)

  if ! view_output=$(gh release view "${VERSION}" --repo "${repo}" 2>&1); then
    # `gh release view` uses this phrase for an absent tag. Do not flatten every
    # non-zero result into "no release": authentication, rate-limit, and network
    # failures need to retain their real diagnostic.
    if grep -qiE 'release not found|no release found for' <<<"${view_output}"; then
      lookup_rc=3
    else
      lookup_rc=4
    fi
  fi

  if [[ "${lookup_rc}" -ne 0 ]]; then
    if [[ "${DRY_RUN}" == "true" && "${preview_missing}" == "true" ]]; then
      if [[ "${lookup_rc}" -eq 3 ]]; then
        echo "::warning::no ${VERSION} release found on ${repo} (dry-run: printing the planned promotion anyway)"
      else
        echo "::warning::failed to inspect ${repo}@${VERSION} (${view_output}); dry-run: printing the planned promotion anyway" >&2
      fi
    elif [[ "${failure_mode}" == "required" ]]; then
      if [[ "${lookup_rc}" -eq 3 ]]; then
        echo "::error::no ${VERSION} release found on ${repo}, so its Latest pointer cannot be established. Refusing to retag the moving tags. Nothing has changed yet; publish the release and re-run the promotion." >&2
      else
        echo "::error::failed to inspect ${repo}@${VERSION} (${view_output}), so its Latest pointer cannot be established. Refusing to retag the moving tags. Nothing has changed yet; re-run once the release is readable." >&2
      fi
      exit 1
    else
      if [[ "${lookup_rc}" -eq 3 ]]; then
        echo "::warning::no ${VERSION} release found on ${repo}; skipping its promotion"
      else
        echo "::warning::failed to inspect ${repo}@${VERSION} (${view_output}); skipping its promotion" >&2
      fi
      return "${lookup_rc}"
    fi
  fi

  if [[ "${advance_latest}" == "true" ]]; then
    edit_args+=(--latest)
    latest_note=", set latest"
  else
    echo "::notice::not marking ${repo}@${VERSION} as Latest: ${skip_reason}."
  fi

  echo "Promoting ${repo}@${VERSION}: unset prerelease${latest_note}"
  if ! run gh release edit "${VERSION}" --repo "${repo}" "${edit_args[@]}"; then
    if [[ "${failure_mode}" == "required" ]]; then
      echo "::error::failed to set ${repo}@${VERSION} as Latest with: gh release edit ${VERSION} --repo ${repo} ${edit_args[*]}. Refusing to retag the moving tags, since :latest would then be ahead of the pointer this action reads as its backport baseline. Nothing else has changed; re-run this promotion (it is idempotent)." >&2
      exit 1
    fi
    echo "::warning::gh release edit failed for ${repo}@${VERSION}.${prior_note:+ ${prior_note}} Promote manually: gh release edit ${VERSION} --repo ${repo} ${edit_args[*]}" >&2
    return 5
  fi
}

# --- Caller repo's own release -------------------------------------------
#
# Deliberately BEFORE the docker retags, and after the source-manifest
# pre-flight above. This edit writes the caller's Latest pointer, which is the
# very pointer is_at_or_after_latest_pointer() reads back as the unscoped
# backport baseline
# on every later run. If the retags moved first and this then failed, the
# pointer would sit BEHIND :latest, and the next dispatch for an older line
# would pass that stale gate and drag :latest backwards. Establishing the
# pointer first inverts the failure mode: a later crane failure leaves the
# pointer AHEAD, which is the conservative direction - it can only refuse a
# subsequent older promotion, never permit a regression - and re-promoting this
# same version is still allowed, so a plain re-run recovers.
#
# Only meaningful when the caller publishes stable cuts with the GitHub "None"
# label (release.prerelease: auto + make_latest: false in goreleaser): the
# release exists, is not a pre-release, and is not Latest, so promoting it is
# an explicit act rather than a human un-checking a box. Both edits are safe to
# repeat:
#   --latest         gated by ADVANCE_LATEST_MAJOR, the same gate as :latest,
#                    so a backport promotion never moves the repo's Latest
#                    pointer backwards while its line tag still advances.
#   --prerelease=false  a no-op for an auto-classified stable cut; it is what
#                    promotes a legacy tag still built under prerelease: true.
if [[ "${PROMOTE_SELF}" == "true" ]]; then
  if [[ "${ADVANCE_LATEST_MAJOR}" == "true" ]]; then
    promote_gh_release "${GITHUB_REPOSITORY}" true required true
  else
    promote_gh_release "${GITHUB_REPOSITORY}" false advisory true "" "${VERSION} is behind ${CALLER_BASELINE_NOTE}" || true
  fi
else
  echo "promote-self not enabled; leaving ${GITHUB_REPOSITORY}'s own release untouched"
fi

# --- Docker moving tags ------------------------------------------------

for ((i = 0; i < IMAGE_COUNT; i++)); do
  entry=$(jq -c ".[$i]" <<<"${INPUT_IMAGES}")
  image=$(jq -r '.image' <<<"${entry}")
  suffix=$(jq -r '.suffix // ""' <<<"${entry}")

  src="${image}:${VERSION}${suffix}"
  moving_tags=()
  [[ "${ADVANCE_LATEST_MAJOR}" == "true" ]] && moving_tags+=(latest "${MAJOR}")
  [[ "${ADVANCE_MINOR}" == "true" ]] && moving_tags+=("${MAJOR}.${MINOR}")
  if [[ "${#moving_tags[@]}" -eq 0 ]]; then
    echo "::notice::${src}: no moving tags to advance (VERSION is superseded both overall and within its own line); nothing to retag."
    continue
  fi
  for moving in "${moving_tags[@]}"; do
    dest="${image}:${moving}${suffix}"
    echo "Retagging ${dest} -> ${src}"
    # crane tag SRC NEWTAG re-points NEWTAG (in SRC's repo) at SRC's exact
    # manifest digest -- digest-preserving for both single-platform manifests
    # and indexes, so per-arch moving tags stay cosign-verifiable (see header).
    run crane tag "${src}" "${moving}${suffix}"
  done
done

# --- Paired public release ----------------------------------------------

# Whether VERSION is the newest stable on OSS_REPO. Computed once, in the
# block below, and reused by the Homebrew section - so the advisory Homebrew
# step doesn't fire a second `gh release list` (that duplicated the work and,
# via fetch_release_list's fail-closed exit, could hard-fail the whole run for a
# transient list blip after everything else already succeeded). States:
#   "true"    - VERSION is newest; promote --latest and the Homebrew tap.
#   "false"   - confirmed backport; skip --latest and skip Homebrew (a formula
#               has no line-scoped equivalent to :{major}.{minor}).
#   "unknown" - list failed, couldn't confirm; skip --latest and Homebrew but
#               warn it's retryable, NOT a backport.
#   "missing" - no matching oss-repo release.
#   "lookup-failed" - the release lookup failed for a retryable reason.
#   "edit-failed" - the paired release could not be promoted; skip Homebrew so
#                   it cannot advance ahead of the release consumers follow.
#   ""        - never computed (no oss-repo configured).
OSS_IS_LATEST=""
if [[ -n "${OSS_REPO}" ]]; then
  oss_rc=0
  OSS_ADVANCE_LATEST=false
  OSS_BASELINE_NOTE="release ordering could not be confirmed"
  OSS_SKIP_REASON="release ordering could not be confirmed"
  fetch_release_list "${OSS_REPO}" soft || oss_rc=$?
  if [[ "${oss_rc}" -eq 0 ]] && is_at_or_after_latest_pointer "${OSS_REPO}" "${RELEASE_LIST}"; then
    OSS_BASELINE_NOTE="${LATEST_BASELINE_NOTE}"
    if [[ "${ADVANCE_LATEST_MAJOR}" == "true" ]]; then
      OSS_IS_LATEST=true
      OSS_ADVANCE_LATEST=true
    else
      # The caller's Latest pointer is also the Docker moving-tag baseline and
      # therefore the authoritative upper bound for this coordinated release.
      # Requiring both repositories to pass prevents a stale OSS pointer (for
      # example after an earlier advisory edit failure) from promoting a caller
      # backport as OSS Latest or moving the Homebrew formula backwards.
      OSS_IS_LATEST=false
      OSS_BASELINE_NOTE="caller ${CALLER_BASELINE_NOTE}"
      OSS_SKIP_REASON="${VERSION} is behind ${CALLER_BASELINE_NOTE} on ${GITHUB_REPOSITORY}"
      echo "::notice::${VERSION} is behind the caller's promotion baseline (${CALLER_BASELINE_NOTE}); unsetting pre-release on ${OSS_REPO} but not moving Latest."
    fi
  elif [[ "${oss_rc}" -eq 0 ]]; then
    OSS_IS_LATEST=false
    OSS_BASELINE_NOTE="${LATEST_BASELINE_NOTE}"
    OSS_SKIP_REASON="${VERSION} is behind ${LATEST_BASELINE_NOTE}"
    echo "::notice::${VERSION} is older than the promotion baseline on ${OSS_REPO} (${LATEST_BASELINE_NOTE}); unsetting pre-release but not moving Latest."
  else
    # The list warning was already emitted. Keep this distinct from a confirmed
    # backport so the Homebrew gate reports a retryable lookup failure.
    OSS_IS_LATEST=unknown
  fi

  promote_rc=0
  promote_gh_release "${OSS_REPO}" "${OSS_ADVANCE_LATEST}" advisory false "Docker retags are already complete." "${OSS_SKIP_REASON}" || promote_rc=$?
  case "${promote_rc}" in
    0) ;;
    3) OSS_IS_LATEST=missing ;;
    5) OSS_IS_LATEST=edit-failed ;;
    *) OSS_IS_LATEST=lookup-failed ;;
  esac
else
  echo "No oss-repo configured; skipping paired release promotion"
fi

# --- Homebrew tap --------------------------------------------------------
#
# Patches an existing formula file in place rather than re-templating it:
# swap every url's tag segment (every platform in a formula shares the same
# tag), rewrite the sha256 on the line immediately following each url - the
# value comes straight from oss-repo's already-published, already-signed
# checksums.txt, never re-hashed - and rewrite the single top-level version
# line. Everything else in the file (deps, install blocks, test block) is
# untouched byte-for-byte.
#
# All matching/rewriting of interpolated values (the tag, the artifact names)
# is done with awk literal string ops (index/substr), never by splicing those
# values into a regex. A tag like v0.37.1 or an artifact name containing a "."
# or "+" would, as a regex, match any character and could rewrite the wrong
# line; as a literal it matches only itself. The version rewrite is likewise
# anchored to the first top-level (2-space-indent) `version "..."` so a nested
# `resource "..." do ... version "..." ... end` pin is left alone.

# Rewrites $2 (a local copy of the formula) to point at $1 (the promoted
# version), using checksums from $3 (a local copy of oss-repo's
# checksums.txt). Skips (warns, returns 0) rather than fails on any error,
# since Homebrew promotion is advisory - the docker retags (and oss-repo
# promotion, if configured) already succeeded by the time this runs.
patch_homebrew_formula() {
  local new_tag="$1" content_file="$2" checksums_file="$3" tap_repo="$4" formula_path="$5"
  local old_tag

  # `|| true`: under `set -euo pipefail` a no-match `grep` (exit 1) would
  # propagate through the pipe and kill the run before the warn-and-skip
  # guard below can handle it - the opposite of this advisory step's contract.
  old_tag=$(grep -oP 'download/\K[^/]+' "${content_file}" | head -1 || true)
  if [[ -z "${old_tag}" ]]; then
    echo "::warning::no download URL found in ${tap_repo}/${formula_path}; skipping"
    return 0
  fi
  # old_tag is read from the fetched formula, so a tap-repo committer controls
  # it. It's only ever used below as literal data (awk index/substr, never a
  # shell/sed/regex program), but validate it to a release-tag shape anyway as
  # defense-in-depth: bounding it to [v0-9.-] means it can't carry awk -v
  # ANSI-C escape sequences, and a formula not pinned to a recognizable release
  # tag is a shape this promoter doesn't understand - warn-skip over mangle.
  if [[ ! "${old_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]]; then
    echo "::warning::unrecognized version tag '${old_tag}' in ${tap_repo}/${formula_path}; skipping"
    return 0
  fi

  # Single literal-string pass: for each url line, swap old_tag->new_tag,
  # capture the artifact (the url's trailing path segment), and rewrite the
  # sha256 on the very next line from checksums.txt; rewrite only the first
  # top-level `version "..."`. No interpolated value is ever used as a regex.
  awk -v old_tag="${old_tag}" -v new_tag="${new_tag}" -v new_ver="${new_tag#v}" \
      -v checksums="${checksums_file}" -v tap="${tap_repo}" \
      -v fp="${formula_path}" -v ossrepo="${OSS_REPO}" '
    BEGIN {
      # checksums.txt lines are "<sha>  <filename>"; default FS handles the
      # leading/trailing whitespace and the two-space separator.
      while ((getline line < checksums) > 0)
        if (split(line, f) >= 2) sha[f[2]] = f[1]
      old_url = "download/" old_tag "/"
      new_url = "download/" new_tag "/"
    }
    {
      pos = index($0, old_url)
      if (pos > 0) {
        $0 = substr($0, 1, pos - 1) new_url substr($0, pos + length(old_url))
        rest = substr($0, pos + length(new_url))
        q = index(rest, "\""); if (q > 0) rest = substr(rest, 1, q - 1)
        print
        if ((getline shaline) > 0) {
          if (rest in sha) {
            p = index(shaline, "sha256 \"")
            if (p > 0) {
              head = substr(shaline, 1, p - 1) "sha256 \""
              tail = substr(shaline, p + length("sha256 \""))
              qq = index(tail, "\"")
              if (qq > 0) shaline = head sha[rest] substr(tail, qq)
            }
          } else {
            print "::warning::" tap "/" fp ": no checksum for " rest " in " ossrepo "@" new_tag " checksums.txt; leaving its sha256 untouched" > "/dev/stderr"
          }
          print shaline
        }
        next
      }
      if (!ver_done && $0 ~ /^  version "[^"]*"/) {
        sub(/version "[^"]*"/, "version \"" new_ver "\"")
        ver_done = 1
      }
      print
    }
  ' "${content_file}" > "${content_file}.next"
  mv "${content_file}.next" "${content_file}"
}

promote_homebrew_formula() {
  local tap_repo="$1" formula_path="$2" checksums_file="$3"
  local get_raw current_sha content_file new_content_b64

  if ! get_raw=$(gh api "repos/${tap_repo}/contents/${formula_path}" 2>&1); then
    echo "::warning::failed to fetch ${tap_repo}/${formula_path}; skipping: ${get_raw}"
    return 0
  fi
  # `// empty` (not a bare `.sha`): jq renders a missing/null field as the
  # literal string "null", which is non-empty and would sail into `-f sha=`
  # on the PUT below and 422. Guard it here so an unexpected response
  # warn-skips instead of silently leaving the formula unpatched.
  current_sha=$(jq -r '.sha // empty' <<<"${get_raw}")
  if [[ -z "${current_sha}" ]]; then
    echo "::warning::unexpected API response for ${tap_repo}/${formula_path} (missing sha field); skipping"
    return 0
  fi
  content_file=$(mktemp)
  # Guard the decode: it's the one step in this advisory block that could
  # otherwise hard-fail the run post-retag (jq/base64 failure would propagate
  # under `set -euo pipefail`). Warn-skip instead, like every other step here.
  if ! jq -r '.content' <<<"${get_raw}" | base64 -d > "${content_file}" 2>/dev/null; then
    echo "::warning::failed to decode ${tap_repo}/${formula_path} contents (unexpected API response); skipping"
    return 0
  fi

  patch_homebrew_formula "${VERSION}" "${content_file}" "${checksums_file}" "${tap_repo}" "${formula_path}"

  echo "Updating ${tap_repo}/${formula_path} -> ${VERSION}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api -X PUT repos/${tap_repo}/contents/${formula_path} (sha=${current_sha})"
    return 0
  fi
  new_content_b64=$(base64 -w0 "${content_file}")
  if ! gh api -X PUT "repos/${tap_repo}/contents/${formula_path}" \
      -f message="chore: bump ${formula_path} to ${VERSION}" \
      -f content="${new_content_b64}" \
      -f sha="${current_sha}" >/dev/null; then
    echo "::warning::failed to update ${tap_repo}/${formula_path} to ${VERSION}; docker retags (and oss-repo promotion, if configured) already succeeded. Re-run this action to retry the tap update - it is idempotent (crane tag and the formula patch both re-apply cleanly)."
  fi
}

if [[ -n "${HOMEBREW_TAP_REPO}" ]]; then
  case "${OSS_IS_LATEST}" in
    true)
      checksums_file=$(mktemp)
      if ! gh release download "${VERSION}" --repo "${OSS_REPO}" -p 'checksums.txt' -O "${checksums_file}" --clobber 2>&1; then
        echo "::warning::failed to download checksums.txt from ${OSS_REPO}@${VERSION}; skipping Homebrew tap promotion"
      else
        formula_count=$(jq -r 'length' <<<"${HOMEBREW_FORMULA_PATHS}")
        for ((i = 0; i < formula_count; i++)); do
          formula_path=$(jq -r ".[$i]" <<<"${HOMEBREW_FORMULA_PATHS}")
          promote_homebrew_formula "${HOMEBREW_TAP_REPO}" "${formula_path}" "${checksums_file}"
        done
      fi
      ;;
    false)
      echo "::notice::${VERSION} is older than the promotion baseline on ${OSS_REPO} (${OSS_BASELINE_NOTE}); skipping Homebrew tap promotion entirely - a formula has no line-scoped equivalent to :{major}.{minor}."
      ;;
    unknown)
      # Distinct from a backport: we couldn't confirm newest (the oss-repo list
      # failed earlier), so skip rather than risk patching the tap off a stale
      # ordering - but say so accurately and flag it as retryable, since a real
      # newest-release promotion may have just been skipped by a transient blip.
      echo "::warning::could not confirm ${VERSION} is the newest stable release on ${OSS_REPO} (its release list failed earlier); skipping Homebrew tap promotion. Re-run the action to update the tap once the API recovers."
      ;;
    missing)
      echo "::warning::no ${VERSION} release on ${OSS_REPO} to source checksums from; skipping Homebrew tap promotion"
      ;;
    lookup-failed)
      echo "::warning::could not inspect ${OSS_REPO}@${VERSION} to source Homebrew checksums; skipping Homebrew tap promotion. Re-run the action once the API or repository access recovers."
      ;;
    edit-failed)
      echo "::warning::the release edit for ${OSS_REPO}@${VERSION} failed; skipping Homebrew tap promotion so the formula cannot advance ahead of the paired release. Re-run the action after fixing the release promotion."
      ;;
  esac
else
  echo "No homebrew-tap-repo configured; skipping Homebrew tap promotion"
fi

echo "Promotion of ${VERSION} complete."

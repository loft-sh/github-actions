#!/usr/bin/env bash
# Promote a just-published stable release: retag docker moving tags onto the
# version's already-published, already-signed manifest (a digest-preserving
# copy via `docker buildx imagetools create`, never a rebuild -- cosign
# signatures are digest-scoped OCI referrers, so the copy stays verifiable
# with no re-signing), and optionally flip a paired public release off
# pre-release + onto latest.
#
# Only acts on a stable vX.Y.Z version; any other shape (has a "-" suffix) is
# a no-op, since moving tags and "latest" promotion aren't meaningful for
# -rc/-alpha/-next cuts.
#
# Required env:
#   GH_TOKEN        Token with GHCR write:packages, and contents:write on
#                    INPUT_OSS_REPO and INPUT_HOMEBREW_TAP_REPO if set. Docker
#                    login happens in the calling action.yml step, before this
#                    script runs.
#   INPUT_VERSION    The promoted release tag, e.g. v0.37.1.
#   INPUT_IMAGES     JSON array of image entries to retag, each
#                    {"image": "ghcr.io/loft-sh/x", "suffix": ""} (suffix
#                    optional, default ""). For each entry, copies
#                    <image>:<version><suffix> to <image>:latest<suffix>,
#                    <image>:<major><suffix>, and <image>:<major>.<minor><suffix>.
#
# Optional env:
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
#   INPUT_DRY_RUN    "true" prints the planned retags/promotion without
#                     executing them. Default "false".
#
# GITHUB_REPOSITORY (owner/repo of the caller, set automatically by Actions)
# is used to detect a backport/patch promotion: if VERSION isn't the newest
# stable release on that repo, :latest/:{major} are left alone (only
# :{major}.{minor}, which is scoped to VERSION's own line, still advances) so
# promoting an older line's patch can never move :latest backwards.
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
HOMEBREW_TAP_REPO="${INPUT_HOMEBREW_TAP_REPO-}"
HOMEBREW_FORMULA_PATHS="${INPUT_HOMEBREW_FORMULA_PATHS:-[]}"
DRY_RUN="${INPUT_DRY_RUN:-false}"

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

# True if VERSION is the newest stable (non-prerelease) release known on
# $1 - i.e. safe to move that repo's :latest/--latest pointer to VERSION.
# No prior stable releases at all is treated as "yes" (first-ever
# promotion). A failure to even LIST releases is NOT treated as "no prior
# releases" - that would fail open on exactly the downgrade this check
# exists to prevent - so it hard-errors instead, matching the existing
# Homebrew-tap downgrade guard's fail-closed precedent (release.yaml
# check_latest_stable).
is_latest_stable() {
  local repo="$1" raw max
  if ! raw=$(gh release list --repo "${repo}" --json tagName,isPrerelease --limit 100 2>&1); then
    echo "::error::failed to list releases on ${repo} to check backport/patch ordering: ${raw}" >&2
    exit 1
  fi
  max=$(jq -r '[.[] | select(.isPrerelease == false) | .tagName][]' <<<"${raw}" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -1)
  [ -z "${max}" ] && return 0
  [ "$(printf '%s\n%s\n' "${VERSION}" "${max}" | sort -V | tail -1)" = "${VERSION}" ]
}

ADVANCE_LATEST_MAJOR=true
if ! is_latest_stable "${GITHUB_REPOSITORY}"; then
  ADVANCE_LATEST_MAJOR=false
  echo "::notice::${VERSION} is not the newest stable release on ${GITHUB_REPOSITORY} (backport/patch promotion); skipping :latest/:${MAJOR} so they aren't moved backwards. :${MAJOR}.${MINOR} still advances."
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
  if [[ "${DRY_RUN}" != "true" ]] && ! docker buildx imagetools inspect "${image}:${VERSION}${suffix}" >/dev/null 2>&1; then
    echo "::error::source manifest ${image}:${VERSION}${suffix} does not exist; refusing to start retagging" >&2
    exit 1
  fi
done

# --- Docker moving tags ------------------------------------------------

for ((i = 0; i < IMAGE_COUNT; i++)); do
  entry=$(jq -c ".[$i]" <<<"${INPUT_IMAGES}")
  image=$(jq -r '.image' <<<"${entry}")
  suffix=$(jq -r '.suffix // ""' <<<"${entry}")

  src="${image}:${VERSION}${suffix}"
  moving_tags=("${MAJOR}.${MINOR}")
  [[ "${ADVANCE_LATEST_MAJOR}" == "true" ]] && moving_tags=(latest "${MAJOR}" "${MAJOR}.${MINOR}")
  for moving in "${moving_tags[@]}"; do
    dest="${image}:${moving}${suffix}"
    echo "Retagging ${dest} -> ${src}"
    run docker buildx imagetools create --tag "${dest}" "${src}"
  done
done

# --- Paired public release ----------------------------------------------

# Whether VERSION is the newest stable on OSS_REPO. Computed once, in the
# block below, and reused by the Homebrew section - so the advisory Homebrew
# step doesn't fire a second `gh release list` (that duplicated the work and,
# via is_latest_stable's fail-closed exit, could hard-fail the whole run for a
# transient list blip after everything else already succeeded). "" means we
# never got to compute it (no matching oss-repo release).
OSS_IS_LATEST=""
if [[ -n "${OSS_REPO}" ]]; then
  if gh release view "${VERSION}" --repo "${OSS_REPO}" >/dev/null 2>&1; then
    edit_args=(--prerelease=false)
    latest_note=""
    if is_latest_stable "${OSS_REPO}"; then
      OSS_IS_LATEST=true
      edit_args+=(--latest)
      latest_note=", set latest"
    else
      OSS_IS_LATEST=false
      echo "::notice::${VERSION} is not the newest stable release on ${OSS_REPO} (backport/patch promotion); unsetting pre-release but not moving Latest."
    fi
    echo "Promoting ${OSS_REPO}@${VERSION}: unset prerelease${latest_note}"
    if ! run gh release edit "${VERSION}" --repo "${OSS_REPO}" "${edit_args[@]}"; then
      echo "::warning::gh release edit failed for ${OSS_REPO}@${VERSION}; docker retags are already complete. Promote manually: gh release edit ${VERSION} --repo ${OSS_REPO} ${edit_args[*]}"
    fi
  else
    echo "::warning::no ${VERSION} release found on ${OSS_REPO}; skipping its promotion"
  fi
else
  echo "No oss-repo configured; skipping paired release promotion"
fi

# --- Homebrew tap --------------------------------------------------------
#
# Patches an existing formula file in place rather than re-templating it:
# swap the version and every url's tag segment (one sed pass, since every
# platform in a formula shares the same tag), then for each artifact found
# in the file, rewrite the sha256 on the line immediately following its url
# - the value comes straight from oss-repo's already-published, already-
# signed checksums.txt, never re-hashed. Everything else in the file
# (deps, install blocks, test block) is untouched byte-for-byte.

# Rewrites $2 (a local copy of the formula) to point at $1 (the promoted
# version), using checksums from $3 (a local copy of oss-repo's
# checksums.txt). Skips (warns, returns 0) rather than fails on any error,
# since Homebrew promotion is advisory - the docker retags (and oss-repo
# promotion, if configured) already succeeded by the time this runs.
patch_homebrew_formula() {
  local new_tag="$1" content_file="$2" checksums_file="$3" tap_repo="$4" formula_path="$5"
  local old_tag artifact new_sha

  # `|| true`: under `set -euo pipefail` a no-match `grep` (exit 1) would
  # propagate through the pipe and kill the run before the warn-and-skip
  # guard below can handle it - the opposite of this advisory step's contract.
  old_tag=$(grep -oP 'download/\K[^/]+' "${content_file}" | head -1 || true)
  if [[ -z "${old_tag}" ]]; then
    echo "::warning::no download URL found in ${tap_repo}/${formula_path}; skipping"
    return 0
  fi

  sed -i "s|download/${old_tag}/|download/${new_tag}/|g" "${content_file}"

  while IFS= read -r artifact; do
    [[ -z "${artifact}" ]] && continue
    new_sha=$(awk -v a="${artifact}" '$2==a {print $1}' "${checksums_file}")
    if [[ -z "${new_sha}" ]]; then
      echo "::warning::${tap_repo}/${formula_path}: no checksum for ${artifact} in ${OSS_REPO}@${new_tag}'s checksums.txt; leaving its sha256 untouched"
      continue
    fi
    awk -v artifact="${artifact}" -v new_sha="${new_sha}" '
      $0 ~ ("/" artifact "\"$") {
        print
        getline
        sub(/sha256 "[^"]+"/, "sha256 \"" new_sha "\"")
        print
        next
      }
      { print }
    ' "${content_file}" > "${content_file}.next"
    mv "${content_file}.next" "${content_file}"
  done < <(grep -oP "download/${new_tag}/\K[^\"]+" "${content_file}")

  sed -i -E "s|(version \")[^\"]*(\")|\1${new_tag#v}\2|" "${content_file}"
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
  jq -r '.content' <<<"${get_raw}" | base64 -d > "${content_file}"

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
    echo "::warning::failed to update ${tap_repo}/${formula_path} to ${VERSION}; docker retags (and oss-repo promotion, if configured) already succeeded. Re-run this action to retry the tap update - it is idempotent (imagetools create and the formula patch both re-apply cleanly)."
  fi
}

if [[ -n "${HOMEBREW_TAP_REPO}" ]]; then
  if [[ "${OSS_IS_LATEST}" == "false" ]]; then
    echo "::notice::${VERSION} is not the newest stable release on ${OSS_REPO} (backport/patch promotion); skipping Homebrew tap promotion entirely - a formula has no line-scoped equivalent to :{major}.{minor}."
  elif [[ "${OSS_IS_LATEST}" != "true" ]]; then
    # Only reachable when the oss-repo release wasn't found above (already
    # warned); without it there are no published checksums to patch from.
    echo "::warning::no ${VERSION} release on ${OSS_REPO} to source checksums from; skipping Homebrew tap promotion"
  else
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
  fi
else
  echo "No homebrew-tap-repo configured; skipping Homebrew tap promotion"
fi

echo "Promotion of ${VERSION} complete."

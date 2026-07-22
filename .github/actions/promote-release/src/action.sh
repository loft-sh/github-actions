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
#                    INPUT_OSS_REPO if set. Docker login happens in the
#                    calling action.yml step, before this script runs.
#   INPUT_VERSION    The promoted release tag, e.g. v0.37.1.
#   INPUT_IMAGES     JSON array of image entries to retag, each
#                    {"image": "ghcr.io/loft-sh/x", "suffix": ""} (suffix
#                    optional, default ""). For each entry, copies
#                    <image>:<version><suffix> to <image>:latest<suffix>,
#                    <image>:<major><suffix>, and <image>:<major>.<minor><suffix>.
#
# Optional env:
#   INPUT_OSS_REPO   owner/repo whose matching <version> release should also
#                     be promoted. Empty (default) skips this step.
#   INPUT_DRY_RUN    "true" prints the planned retags/promotion without
#                     executing them. Default "false".
#
# GITHUB_REPOSITORY (owner/repo of the caller, set automatically by Actions)
# is used to detect a backport/patch promotion: if VERSION isn't the newest
# stable release on that repo, :latest/:{major} are left alone (only
# :{major}.{minor}, which is scoped to VERSION's own line, still advances) so
# promoting an older line's patch can never move :latest backwards.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${INPUT_VERSION:?version required}"
: "${INPUT_IMAGES:?images required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required (set automatically by GitHub Actions)}"

VERSION="${INPUT_VERSION}"
OSS_REPO="${INPUT_OSS_REPO-}"
DRY_RUN="${INPUT_DRY_RUN:-false}"

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

if [[ -n "${OSS_REPO}" ]]; then
  if gh release view "${VERSION}" --repo "${OSS_REPO}" >/dev/null 2>&1; then
    edit_args=(--prerelease=false)
    latest_note=""
    if is_latest_stable "${OSS_REPO}"; then
      edit_args+=(--latest)
      latest_note=", set latest"
    else
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

echo "Promotion of ${VERSION} complete."

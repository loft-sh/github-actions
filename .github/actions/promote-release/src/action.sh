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
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${INPUT_VERSION:?version required}"
: "${INPUT_IMAGES:?images required}"

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

# Validate every entry before making any changes, so a config typo can't
# leave the images partially retagged.
IMAGE_COUNT=$(jq -r 'length' <<<"${INPUT_IMAGES}")
for ((i = 0; i < IMAGE_COUNT; i++)); do
  image=$(jq -r ".[$i].image // empty" <<<"${INPUT_IMAGES}")
  if [[ -z "${image}" ]]; then
    echo "::error::images[$i] is missing required \"image\" field: $(jq -c ".[$i]" <<<"${INPUT_IMAGES}")" >&2
    exit 1
  fi
done

# --- Docker moving tags ------------------------------------------------

for ((i = 0; i < IMAGE_COUNT; i++)); do
  entry=$(jq -c ".[$i]" <<<"${INPUT_IMAGES}")
  image=$(jq -r '.image' <<<"${entry}")
  suffix=$(jq -r '.suffix // ""' <<<"${entry}")

  src="${image}:${VERSION}${suffix}"
  for moving in latest "${MAJOR}" "${MAJOR}.${MINOR}"; do
    dest="${image}:${moving}${suffix}"
    echo "Retagging ${dest} -> ${src}"
    run docker buildx imagetools create --tag "${dest}" "${src}"
  done
done

# --- Paired public release ----------------------------------------------

if [[ -n "${OSS_REPO}" ]]; then
  if gh release view "${VERSION}" --repo "${OSS_REPO}" >/dev/null 2>&1; then
    echo "Promoting ${OSS_REPO}@${VERSION}: unset prerelease, set latest"
    run gh release edit "${VERSION}" --repo "${OSS_REPO}" --prerelease=false --latest
  else
    echo "::warning::no ${VERSION} release found on ${OSS_REPO}; skipping its promotion"
  fi
else
  echo "No oss-repo configured; skipping paired release promotion"
fi

echo "Promotion of ${VERSION} complete."

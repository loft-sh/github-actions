#!/usr/bin/env bash
# Rewrites the tracked container's image tag in the manifest, in place.
#
# Inputs (env):
#   MANIFEST_PATH   Path to the deployment manifest.
#   CONTAINER_NAME  Container whose image is rewritten.
#   IMAGE_REPO      Image repo without tag (e.g. ghcr.io/loft-sh/app).
#   NEW_TAG         Tag to pin (leading v preserved).
set -euo pipefail

: "${MANIFEST_PATH:?MANIFEST_PATH is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME is required}"
: "${IMAGE_REPO:?IMAGE_REPO is required}"
: "${NEW_TAG:?NEW_TAG is required}"

export NEW_IMAGE="${IMAGE_REPO}:${NEW_TAG}"
export CN="$CONTAINER_NAME"

yq eval \
  '(.spec.template.spec.containers[] | select(.name == env(CN)) | .image) = env(NEW_IMAGE)' \
  -i "$MANIFEST_PATH"

echo "set ${CONTAINER_NAME} image to ${NEW_IMAGE} in ${MANIFEST_PATH}"

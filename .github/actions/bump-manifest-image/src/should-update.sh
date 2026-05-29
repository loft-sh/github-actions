#!/usr/bin/env bash
# Decides whether the target manifest should be bumped to NEW_VERSION.
#
# Inputs (env):
#   MANIFEST_PATH   Path to the deployment manifest.
#   CONTAINER_NAME  Container whose image tag is tracked.
#   NEW_VERSION     Incoming version, v-stripped (e.g. 0.2.0).
#   IS_STABLE       true|false — whether NEW_VERSION is a stable release.
#   ENVIRONMENT     Target environment (prod skips pre-releases).
# Outputs ($GITHUB_OUTPUT):
#   should_update   true when a newer, applicable version warrants a PR.
#   current_tag     Existing image tag found in the manifest (empty if none).
#   reason          Human-readable explanation for the decision.
set -euo pipefail

: "${MANIFEST_PATH:?MANIFEST_PATH is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME is required}"
: "${NEW_VERSION:?NEW_VERSION is required}"
: "${IS_STABLE:?IS_STABLE is required}"
: "${ENVIRONMENT:?ENVIRONMENT is required}"

emit() {
  {
    echo "should_update=$1"
    echo "current_tag=${2:-}"
    echo "reason=$3"
  } >> "$GITHUB_OUTPUT"
  echo "$3"
}

if [ ! -f "$MANIFEST_PATH" ]; then
  emit false "" "manifest not found at ${MANIFEST_PATH}"
  exit 0
fi

# Prod never tracks pre-releases.
if [ "$ENVIRONMENT" = "prod" ] && [ "$IS_STABLE" != "true" ]; then
  emit false "" "pre-release skipped for prod"
  exit 0
fi

current_image=$(CN="$CONTAINER_NAME" yq eval \
  '.spec.template.spec.containers[] | select(.name == env(CN)) | .image' \
  "$MANIFEST_PATH")
if [ -z "$current_image" ] || [ "$current_image" = "null" ]; then
  emit false "" "container ${CONTAINER_NAME} not found in ${MANIFEST_PATH}"
  exit 0
fi

current_tag="${current_image##*:}"
current_version="${current_tag#v}"

# Greater-than test via version sort. Equal returns false (no churn).
verlt() {
  [ "$1" != "$2" ] && [ "$1" = "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" ]
}

if [ "$NEW_VERSION" = "$current_version" ]; then
  emit false "$current_tag" "already at ${current_tag}"
elif verlt "$current_version" "$NEW_VERSION"; then
  emit true "$current_tag" "newer than ${current_tag}, will bump"
else
  emit false "$current_tag" "${NEW_VERSION} is not newer than ${current_tag}"
fi

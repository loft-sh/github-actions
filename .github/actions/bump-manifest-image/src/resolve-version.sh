#!/usr/bin/env bash
# Normalises a release tag and derives the bits the downstream steps need.
#
# Inputs (env):
#   RAW_TAG    Release tag as received (e.g. v0.2.0 or 0.2.0-rc1).
#   IMAGE_REPO Full image repo (e.g. ghcr.io/loft-sh/revops-events-api).
# Outputs ($GITHUB_OUTPUT):
#   new_tag      The tag verbatim, leading v preserved (image tags keep it).
#   new_version  Tag with any leading v stripped (for semver comparison).
#   is_stable    true when new_version is a bare X.Y.Z (no pre-release suffix).
#   app_name     Last path segment of IMAGE_REPO (used in PR title/branch).
set -euo pipefail

: "${RAW_TAG:?RAW_TAG is required}"
: "${IMAGE_REPO:?IMAGE_REPO is required}"

new_tag="$RAW_TAG"
new_version="${new_tag#v}"

if [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  is_stable=true
else
  is_stable=false
fi

app_name="${IMAGE_REPO##*/}"

{
  echo "new_tag=${new_tag}"
  echo "new_version=${new_version}"
  echo "is_stable=${is_stable}"
  echo "app_name=${app_name}"
} >> "$GITHUB_OUTPUT"

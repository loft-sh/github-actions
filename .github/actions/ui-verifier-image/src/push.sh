#!/usr/bin/env bash
set -euo pipefail
if [[ ! ${HEAD_SHA:-} =~ ^[0-9a-f]{40}$ ]]; then
  echo 'head-sha must be a full lowercase commit SHA' >&2
  exit 1
fi
image="europe-west3-docker.pkg.dev/loft-prod/ui-verifier/platform:${HEAD_SHA}"
gcloud auth configure-docker europe-west3-docker.pkg.dev --quiet
docker push "$image"
printf 'image=%s\n' "$image" >> "$GITHUB_OUTPUT"

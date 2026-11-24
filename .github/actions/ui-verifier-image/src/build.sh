#!/usr/bin/env bash
set -euo pipefail
if [[ ! ${HEAD_SHA:-} =~ ^[0-9a-f]{40}$ ]] || [[ $(git rev-parse HEAD) != "$HEAD_SHA" ]]; then
  echo 'head-sha must be the full SHA of the checked-out commit' >&2
  exit 1
fi
image="europe-west3-docker.pkg.dev/loft-prod/ui-verifier/platform:${HEAD_SHA}"
just build-image "$image" false

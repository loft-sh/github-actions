#!/usr/bin/env bash
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/image-ref.sh"
image=$(verifier_image_ref)
if [[ $(git rev-parse HEAD) != "$HEAD_SHA" ]]; then
  echo 'head-sha must be the full SHA of the checked-out commit' >&2
  exit 1
fi
just build-image "$image" false

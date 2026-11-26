#!/usr/bin/env bash
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname -- "${BASH_SOURCE[0]}")/image-ref.sh"
image=$(verifier_image_ref)
docker push "$image"
printf 'image=%s\n' "$image" >> "$GITHUB_OUTPUT"

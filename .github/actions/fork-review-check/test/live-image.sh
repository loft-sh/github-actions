#!/usr/bin/env bash
# Runs image mode against the real registry and attestations and checks one
# expectation: WANT=attested means the image's provenance verified, so it is
# listed as an input; WANT=rejected means verification failed and is reported.
set -euo pipefail

receipt=$(mktemp)
go run . image -image "${IMAGE:?}" \
  -signer-workflow loft-sh/kine=.github/workflows/release.yml \
  -upstream loft-sh/kine=k3s-io/kine \
  -advisory -receipt "$receipt"

attested=$(jq '[.inputs[] | select(.kind == "image")] | length' "$receipt")
rejected=$(jq '[.failures[]? | select(contains("verify provenance"))] | length' "$receipt")
case "${WANT:?}" in
  attested) [[ "$attested" == 1 && "$rejected" == 0 ]] ;;
  rejected) [[ "$attested" == 0 && "$rejected" == 1 ]] ;;
  *) echo "::error::WANT must be attested or rejected" >&2; exit 2 ;;
esac || { echo "::error::$IMAGE: want $WANT, got attested=$attested rejected=$rejected" >&2; exit 1; }
echo "$IMAGE: $WANT as expected"

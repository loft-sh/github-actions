#!/usr/bin/env bats
# Coverage for apply-bump.sh: rewrites only the target container's tag.

SCRIPT="$BATS_TEST_DIRNAME/../src/apply-bump.sh"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/deployment.yaml"

setup() { MANIFEST="$(mktemp)"; cp "$FIXTURE" "$MANIFEST"; }
teardown() { rm -f "$MANIFEST"; }

image_of() {
  CN="$1" yq eval '.spec.template.spec.containers[] | select(.name == env(CN)) | .image' "$MANIFEST"
}

@test "rewrites the tracked container image" {
  run env \
    MANIFEST_PATH="$MANIFEST" CONTAINER_NAME=revops-events-api \
    IMAGE_REPO=ghcr.io/loft-sh/revops-events-api NEW_TAG=v0.2.0 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(image_of revops-events-api)" = "ghcr.io/loft-sh/revops-events-api:v0.2.0" ]
}

@test "leaves other containers untouched" {
  run env \
    MANIFEST_PATH="$MANIFEST" CONTAINER_NAME=revops-events-api \
    IMAGE_REPO=ghcr.io/loft-sh/revops-events-api NEW_TAG=v0.2.0 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(image_of sidecar)" = "ghcr.io/loft-sh/sidecar:v9.9.9" ]
}

@test "missing NEW_TAG fails" {
  run env \
    MANIFEST_PATH="$MANIFEST" CONTAINER_NAME=revops-events-api \
    IMAGE_REPO=ghcr.io/loft-sh/revops-events-api "$SCRIPT"
  [ "$status" -ne 0 ]
}

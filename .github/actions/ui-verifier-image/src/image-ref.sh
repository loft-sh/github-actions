#!/usr/bin/env bash

verifier_image_ref() {
  local segment='[a-z0-9][a-z0-9._-]*'
  local repository_pattern="^[a-z0-9-]+-docker[.]pkg[.]dev/[a-z0-9-]+/[a-z0-9-]+/$segment(/$segment)*$"
  if [[ ! ${HEAD_SHA:-} =~ ^[0-9a-f]{40}$ ]]; then
    echo 'head-sha must be a full lowercase commit SHA' >&2
    return 1
  fi
  if [[ ! ${IMAGE_REPOSITORY:-} =~ $repository_pattern ]]; then
    echo 'image-repository must be an Artifact Registry Docker image path without a tag or digest' >&2
    return 1
  fi
  printf '%s:%s\n' "$IMAGE_REPOSITORY" "$HEAD_SHA"
}

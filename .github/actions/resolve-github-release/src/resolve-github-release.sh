#!/usr/bin/env bash
# Resolves a GitHub release version to a concrete tag.
#
# CI workflows that consume another repo's release artifacts usually accept a
# version input defaulting to "latest". Every artifact URL they build needs a
# real tag, and "latest" resolves differently over time, so each workflow ends
# up with the same inline resolve-and-record shell. This action centralizes it:
# "latest" (or "main") is resolved through the GitHub API to the tag of the
# latest published release, anything else passes through as-is.
#
# An explicit tag is deliberately NOT checked for existence: callers pass tags
# for releases that may still be publishing (that ordering problem belongs to
# wait-for-release), and the artifact download fails loudly anyway.
#
# The resolved tag is appended to $GITHUB_STEP_SUMMARY as an audit trail:
# "latest" resolves differently over time, so each run records what it used.
#
# Required env: GH_TOKEN, INPUT_REPO, INPUT_VERSION
# Writes: tag to $GITHUB_OUTPUT (and stdout).
# Exits 0 with a non-empty tag, 1 otherwise.
set -euo pipefail

: "${INPUT_REPO:?INPUT_REPO is required}"
: "${INPUT_VERSION:?INPUT_VERSION is required}"

emit() {
  local key="$1" value="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  printf '%s=%s\n' "$key" "$value"
}

main() {
  local tag="$INPUT_VERSION"

  if [ "$tag" = "latest" ] || [ "$tag" = "main" ]; then
    if ! tag=$(gh api "repos/${INPUT_REPO}/releases/latest" --jq '.tag_name // empty'); then
      echo "::error::could not resolve the latest release of ${INPUT_REPO}"
      return 1
    fi
    if [ -z "$tag" ]; then
      echo "::error::${INPUT_REPO} has no published releases to resolve '${INPUT_VERSION}' against"
      return 1
    fi
    echo "resolved ${INPUT_VERSION} to ${tag}"
  else
    echo "using explicit tag ${tag}"
  fi

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s release used: `%s`\n' "$INPUT_REPO" "$tag" >>"$GITHUB_STEP_SUMMARY"
  fi
  emit tag "$tag"
}

# Only auto-run when executed directly; sourcing (e.g. from bats) must not.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

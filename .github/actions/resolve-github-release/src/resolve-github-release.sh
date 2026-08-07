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

# emit writes the output in the heredoc-delimiter form so a value containing
# newlines cannot forge extra key=value pairs. On the pass-through path `version`
# becomes `tag` verbatim, and future callers of a shared action cannot all be
# audited for where their `version` came from — harden the sink once instead.
emit() {
  local key="$1" value="$2" delim
  delim="GH_OUTPUT_EOF_$(date +%s%N)_$$"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf '%s<<%s\n' "$key" "$delim"
      printf '%s\n' "$value"
      printf '%s\n' "$delim"
    } >>"$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$key" "$value"
}

main() {
  local tag="$INPUT_VERSION"

  if [ "$tag" = "latest" ] || [ "$tag" = "main" ]; then
    # The latest-release endpoint 404s on a repo with no published release and
    # `gh api` exits non-zero on any 4xx, so absent-vs-failed must be classified
    # from stderr — a 200 with an empty tag_name does not happen. Collapsing the
    # two sends an operator debugging a release-less repo after a network or
    # auth problem that does not exist.
    local err_file
    err_file=$(mktemp)
    if ! tag=$(gh api "repos/${INPUT_REPO}/releases/latest" --jq '.tag_name // empty' 2>"$err_file"); then
      if grep -qiE 'not found|HTTP 404' "$err_file"; then
        echo "::error::${INPUT_REPO} has no published releases to resolve '${INPUT_VERSION}' against"
      else
        echo "::error::could not resolve the latest release of ${INPUT_REPO}: $(cat "$err_file")"
      fi
      rm -f "$err_file"
      return 1
    fi
    rm -f "$err_file"
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

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

# Drawn from the kernel once per process rather than from time and pid, so the
# heredoc delimiter emit relies on is unguessable rather than merely unlikely.
# $RANDOM is the documented weak last resort for a runner offering neither
# source; the same tiering is spelled out at length in oss-commit-sync/lib.sh.
OUTPUT_DELIM="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || OUTPUT_DELIM=""
if [ "${#OUTPUT_DELIM}" -ne 32 ]; then
  OUTPUT_DELIM="$({ tr -d '\n-' < /proc/sys/kernel/random/uuid; } 2>/dev/null)" || OUTPUT_DELIM=""
fi
if [ "${#OUTPUT_DELIM}" -ne 32 ]; then
  OUTPUT_DELIM="$(printf '%04x%04x%04x%04x%04x%04x%04x%04x' \
    "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")"
fi

# emit writes the output in the heredoc-delimiter form so a value containing
# newlines cannot forge extra key=value pairs. On the pass-through path `version`
# becomes `tag` verbatim, and future callers of a shared action cannot all be
# audited for where their `version` came from — harden the sink once instead.
emit() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf '%s<<GH_OUTPUT_EOF_%s\n' "$key" "$OUTPUT_DELIM"
      printf '%s\n' "$value"
      printf 'GH_OUTPUT_EOF_%s\n' "$OUTPUT_DELIM"
    } >>"$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$key" "$value"
}

# Strips leading and trailing whitespace. A version arriving from a multi-line
# YAML input or a shell capture carries a trailing newline or stray indentation
# often enough that comparing it raw silently turns "latest" into a literal tag.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Classifies the 404 the latest-release endpoint returns. "no published release"
# and "repo not visible to this token" are indistinguishable on that endpoint —
# a typo'd name, a private repo the token cannot read, and a real release-less
# repo all 404 — so ask the repo endpoint, which only the first two 404 on.
report_404() {
  if gh api "repos/${INPUT_REPO}" --jq '.full_name' >/dev/null 2>&1; then
    echo "::error::${INPUT_REPO} has no published releases to resolve '${INPUT_VERSION}' against"
  else
    echo "::error::${INPUT_REPO} is not visible to this token: check the repository name, and that the token has contents:read on it"
  fi
}

main() {
  local tag
  tag="$(trim "$INPUT_VERSION")"

  if [ "${tag,,}" = "latest" ] || [ "${tag,,}" = "main" ]; then
    # `gh api` exits non-zero on any 4xx, so absent-vs-failed must be classified
    # from stderr. Collapsing the two sends an operator debugging a release-less
    # repo after a network or auth problem that does not exist.
    local err_file
    err_file=$(mktemp)
    if ! tag=$(gh api "repos/${INPUT_REPO}/releases/latest" --jq '.tag_name // empty' 2>"$err_file"); then
      if grep -qiE 'HTTP 404' "$err_file"; then
        report_404
      else
        # gh's stderr is multi-line: only the first line would become the
        # annotation, and any `::`-prefixed line in an API error body would be
        # read as a workflow command. One line keeps the whole error visible.
        echo "::error::could not resolve the latest release of ${INPUT_REPO}: $(tr '\n' ' ' <"$err_file")"
      fi
      rm -f "$err_file"
      return 1
    fi
    rm -f "$err_file"
    # `.tag_name // empty` yields an empty string on any 200 without a
    # tag_name. Emitting that produces an artifact URL with an empty path
    # segment, which fails much later as an opaque 404.
    if [ -z "$tag" ]; then
      echo "::error::the latest release of ${INPUT_REPO} has no tag_name"
      return 1
    fi
    echo "resolved ${INPUT_VERSION} to ${tag}"
  else
    echo "using explicit tag ${tag}"
  fi

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    # A list item, so two steps resolving two repos in one job stay two lines
    # instead of collapsing into one run-together Markdown paragraph.
    printf -- '- %s release used: `%s`\n' "$INPUT_REPO" "$tag" >>"$GITHUB_STEP_SUMMARY"
  fi
  emit tag "$tag"
}

# Only auto-run when executed directly; sourcing (e.g. from bats) must not.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

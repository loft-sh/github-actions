#!/usr/bin/env bash
set -euo pipefail

# Run only from trusted workflow code. Never fall back to the caller's
# repository-scoped GITHUB_TOKEN for this cross-repository check.
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo '::error::Set FORK_REVIEW_READ_TOKEN to an approved read-only token with access to the forks and Metadata: read.' >&2
  exit 1
fi

repo="${REPO:?REPO is required}"
actor="${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
if ! permission=$(gh api "repos/$repo/collaborators/$actor/permission" --jq '.permission'); then
  echo "::error::Cannot read collaborator permissions in $repo. Give FORK_REVIEW_READ_TOKEN access to this fork with Metadata: read; rerun the advisory workflow." >&2
  exit 1
fi

case "$permission" in
  admin|write|read|none)
    echo "Collaborator permission lookup succeeded in $repo."
    ;;
  *)
    echo "::error::No collaborator permission returned for $repo; check the token's repository access before rerunning." >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  echo '::error::Usage: check-access.sh [configuration]' >&2
  exit 2
fi
case "${1:-}" in
  configuration)
    if [[ -z "${CLIENT_ID:-}" || -z "${PRIVATE_KEY:-}" ]]; then
      echo '::error::Configure environment vars.FORK_REVIEW_APP_CLIENT_ID and secrets.FORK_REVIEW_APP_PRIVATE_KEY for the approved GitHub App.' >&2
      exit 1
    fi
    echo 'GitHub App configuration is present.'
    exit 0
    ;;
  '') ;;
  *)
    echo '::error::Usage: check-access.sh [configuration]' >&2
    exit 2
    ;;
esac

# Run only from trusted workflow code. Never fall back to the caller's
# repository-scoped GITHUB_TOKEN for this cross-repository check.
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo '::error::Use a token from the approved read-only GitHub App with access to the forks and Metadata: read.' >&2
  exit 1
fi

repo="${REPO:?REPO is required}"
actor="${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
if ! permission=$(gh api "repos/$repo/collaborators/$actor/permission" --jq '.permission'); then
  echo "::error::Cannot read collaborator permissions in $repo. Give the approved GitHub App access to this fork with Metadata: read; rerun the advisory workflow." >&2
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

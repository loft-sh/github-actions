#!/usr/bin/env bash
# Decides whether a bot-authored PR qualifies for auto-approval.
#
# Required env: TRUSTED_AUTHORS, PR_AUTHOR, PR_TITLE, PR_BRANCH
# Writes: eligible=true|false and reason=<string> to $GITHUB_OUTPUT (and stdout).
# Always exits 0 — decisions flow through the output, never through exit code.
set -euo pipefail

: "${TRUSTED_AUTHORS:?TRUSTED_AUTHORS required}"
: "${PR_AUTHOR:?PR_AUTHOR required}"
PR_TITLE="${PR_TITLE:-}"
PR_BRANCH="${PR_BRANCH:-}"

emit() {
  local k="$1" v="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$k" "$v"
}

IFS=',' read -ra AUTHORS <<< "${TRUSTED_AUTHORS}"
author_trusted=false
for a in "${AUTHORS[@]}"; do
  if [ "$a" = "$PR_AUTHOR" ]; then
    author_trusted=true
    break
  fi
done

if [ "$author_trusted" != "true" ]; then
  echo "::notice::Author '$PR_AUTHOR' not in trusted list"
  emit eligible false
  emit reason ""
  exit 0
fi

# Prerelease platform versions must never be auto-approved — the title
# (chore: update platform version to vX.Y.Z-alpha.N) would otherwise
# match the chore pattern below, bypassing the branch-level check.
if [[ "$PR_BRANCH" =~ ^update-platform-version-.*-(alpha|beta|rc)\. ]]; then
  echo "::warning::Platform version update contains prerelease tag, skipping (branch: $PR_BRANCH)"
  emit eligible false
  emit reason ""
  exit 0
fi

eligible=false
reason=""
if   [[ "$PR_TITLE"  =~ ^chore(\(|:)              ]]; then eligible=true; reason="chore PR"
elif [[ "$PR_TITLE"  =~ ^fix\(deps\)              ]]; then eligible=true; reason="dependency fix PR"
elif [[ "$PR_BRANCH" =~ ^backport/                ]]; then eligible=true; reason="backport PR"
elif [[ "$PR_BRANCH" =~ ^renovate/                ]]; then eligible=true; reason="renovate PR"
elif [[ "$PR_BRANCH" =~ ^update-platform-version- ]]; then eligible=true; reason="platform version update PR"
fi

if [ "$eligible" != "true" ]; then
  echo "::notice::PR not in auto-approve patterns (title='$PR_TITLE' branch='$PR_BRANCH')"
fi

emit eligible "$eligible"
emit reason   "$reason"

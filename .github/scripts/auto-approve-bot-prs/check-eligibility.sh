#!/usr/bin/env bash
set -euo pipefail

# Decides whether a bot-authored PR qualifies for auto-approval.
#
# Exits 0 in all matched/unmatched branches — the eligibility decision
# is communicated via `eligible=<true|false>` and `reason=<string>`
# lines, written to $GITHUB_OUTPUT when set, and always echoed to stdout
# so the script is trivial to invoke from tests and from the workflow.
#
# Required environment variables:
#   TRUSTED_AUTHORS  — comma-separated list of trusted bot logins
#   PR_AUTHOR        — PR author login (github.event.pull_request.user.login)
#   PR_TITLE         — PR title (github.event.pull_request.title)
#   PR_BRANCH        — PR head branch (github.event.pull_request.head.ref)

: "${TRUSTED_AUTHORS:?TRUSTED_AUTHORS is required}"
: "${PR_AUTHOR:?PR_AUTHOR is required}"
# Allow empty title/branch so the script still returns a clean "not eligible"
# rather than failing hard — GitHub always populates these, but tests may not.
PR_TITLE="${PR_TITLE:-}"
PR_BRANCH="${PR_BRANCH:-}"

emit() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$key" "$value"
}

# Exact-match author against trusted list.
IFS=',' read -ra AUTHORS <<< "${TRUSTED_AUTHORS}"
author_trusted=false
for author in "${AUTHORS[@]}"; do
  if [ "${author}" = "${PR_AUTHOR}" ]; then
    author_trusted=true
    break
  fi
done

if [ "${author_trusted}" != "true" ]; then
  echo "Author '${PR_AUTHOR}' not in trusted list, skipping" >&2
  emit eligible false
  emit reason ""
  exit 0
fi

eligible=false
reason=""
if   [[ "${PR_TITLE}"  =~ ^chore(\(|:)           ]]; then eligible=true; reason="chore PR"
elif [[ "${PR_TITLE}"  =~ ^fix\(deps\)           ]]; then eligible=true; reason="dependency fix PR"
elif [[ "${PR_BRANCH}" =~ ^backport/             ]]; then eligible=true; reason="backport PR"
elif [[ "${PR_BRANCH}" =~ ^renovate/             ]]; then eligible=true; reason="renovate PR"
elif [[ "${PR_BRANCH}" =~ ^update-platform-version- ]]; then eligible=true; reason="platform version update PR"
fi

if [ "${eligible}" != "true" ]; then
  echo "PR does not match auto-approve patterns (title: ${PR_TITLE}, branch: ${PR_BRANCH})" >&2
fi

emit eligible "${eligible}"
emit reason "${reason}"

#!/usr/bin/env bash
# Resolve the optional GitHub-label field and repository links used by the
# success banner. Keeping these branches outside the Block Kit YAML makes the
# link targets and labels directly testable.
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
: "${TARGET_REPO:?TARGET_REPO required}"
: "${VERSION:?VERSION required}"

PAIRED_REPO="${PAIRED_REPO-}"
PREVIOUS_TAG="${PREVIOUS_TAG-}"
IS_PRERELEASE="${IS_PRERELEASE:-false}"
NEEDS_PROMOTION="${NEEDS_PROMOTION:-false}"
PROMOTE_WORKFLOW="${PROMOTE_WORKFLOW:-promote-release.yaml}"

label_field=""
if [[ "${NEEDS_PROMOTION}" == "true" ]]; then
  label_field="- {\"type\": \"mrkdwn\", \"text\": \"*GitHub label:*\\n\`None\` - not Latest yet. <https://github.com/${TARGET_REPO}/actions/workflows/${PROMOTE_WORKFLOW}|Promote it> to unset pre-release and, when this is the newest release, move Latest, the moving image tags and the Homebrew formula.\"}"
elif [[ "${IS_PRERELEASE}" == "true" ]]; then
  label_field='- {"type": "mrkdwn", "text": "*GitHub label:*\nPre-release"}'
fi

if [[ -n "${PAIRED_REPO}" ]]; then
  changelog_text="<https://github.com/${TARGET_REPO}/compare/${PREVIOUS_TAG}...${VERSION}|${TARGET_REPO}> | <https://github.com/${PAIRED_REPO}/compare/${PREVIOUS_TAG}...${VERSION}|${PAIRED_REPO}>"
  release_text="Releases: <https://github.com/${TARGET_REPO}/releases/tag/${VERSION}|${TARGET_REPO}> | <https://github.com/${PAIRED_REPO}/releases/tag/${VERSION}|${PAIRED_REPO}>"
else
  changelog_text="<https://github.com/${TARGET_REPO}/compare/${PREVIOUS_TAG}...${VERSION}|View Full Changelog>"
  release_text="<https://github.com/${TARGET_REPO}/releases/tag/${VERSION}|View Release>"
fi

{
  printf 'label_field=%s\n' "${label_field}"
  printf 'changelog_text=%s\n' "${changelog_text}"
  printf 'release_text=%s\n' "${release_text}"
} >> "${GITHUB_OUTPUT}"

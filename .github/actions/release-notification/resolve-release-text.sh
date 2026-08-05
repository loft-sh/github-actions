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
  # Single quotes keep Slack backticks literal; TARGET_REPO and
  # PROMOTE_WORKFLOW are supplied through printf %s arguments.
  # shellcheck disable=SC2016
  printf -v label_text '*GitHub label:*\n`None` - not Latest yet. <https://github.com/%s/actions/workflows/%s|Promote it> to unset pre-release and, when this is the newest release, move Latest, the moving image tags and the Homebrew formula.' "${TARGET_REPO}" "${PROMOTE_WORKFLOW}"
  label_field="- $(jq -nc --arg text "${label_text}" '{type:"mrkdwn",text:$text}')"
elif [[ "${IS_PRERELEASE}" == "true" ]]; then
  label_field="- $(jq -nc --arg text $'*GitHub label:*\nPre-release' '{type:"mrkdwn",text:$text}')"
fi

if [[ -n "${PREVIOUS_TAG}" && -n "${PAIRED_REPO}" ]]; then
  changelog_text="<https://github.com/${TARGET_REPO}/compare/${PREVIOUS_TAG}...${VERSION}|${TARGET_REPO}> | <https://github.com/${PAIRED_REPO}/compare/${PREVIOUS_TAG}...${VERSION}|${PAIRED_REPO}>"
elif [[ -n "${PREVIOUS_TAG}" ]]; then
  changelog_text="<https://github.com/${TARGET_REPO}/compare/${PREVIOUS_TAG}...${VERSION}|View Full Changelog>"
elif [[ -n "${PAIRED_REPO}" ]]; then
  # A first release has no previous tag to compare against. Link its release
  # notes rather than emitting the invalid /compare/...VERSION URL.
  changelog_text="<https://github.com/${TARGET_REPO}/releases/tag/${VERSION}|${TARGET_REPO}> | <https://github.com/${PAIRED_REPO}/releases/tag/${VERSION}|${PAIRED_REPO}>"
else
  changelog_text="<https://github.com/${TARGET_REPO}/releases/tag/${VERSION}|View Release Notes>"
fi

if [[ -n "${PAIRED_REPO}" ]]; then
  release_text="Releases: <https://github.com/${TARGET_REPO}/releases/tag/${VERSION}|${TARGET_REPO}> | <https://github.com/${PAIRED_REPO}/releases/tag/${VERSION}|${PAIRED_REPO}>"
else
  release_text="<https://github.com/${TARGET_REPO}/releases/tag/${VERSION}|View Release>"
fi

# These JSON scalars are embedded directly in the Block Kit YAML. jq escapes
# quotes, backslashes, and control characters so a legal-but-unusual tag or a
# workflow filename cannot break out of the YAML scalar.
changes_json=$(jq -nc --arg text $'*Changes:*\n'"${changelog_text}" '$text')
release_json=$(jq -nc --arg text "${release_text}" '$text')

write_output() {
  local name="$1" value="$2" delimiter
  delimiter="ghadelim_${RANDOM}_${RANDOM}_$$"
  while grep -Fxq "${delimiter}" <<<"${value}"; do
    delimiter="ghadelim_${RANDOM}_${RANDOM}_$$"
  done
  {
    printf '%s<<%s\n' "${name}" "${delimiter}"
    printf '%s\n' "${value}"
    printf '%s\n' "${delimiter}"
  } >> "${GITHUB_OUTPUT}"
}

write_output label_field "${label_field}"
write_output changelog_text "${changelog_text}"
write_output release_text "${release_text}"
write_output changes_json "${changes_json}"
write_output release_json "${release_json}"

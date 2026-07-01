#!/usr/bin/env bash
# Manage a release-branch code freeze via a GitHub repository ruleset.
#
# The freeze is a single reusable ruleset per repo (default name
# "release-branch-code-freeze") carrying the "Restrict updates" rule. Only
# actors on its bypass list can update (merge into) the targeted branch, and a
# PR merge counts as an update, so non-bypass users cannot merge during a freeze.
#
#   freeze    upsert the ruleset so it targets refs/heads/<branch> with the
#             chosen enforcement and a bypass team. That team is then the only
#             one that can merge into the branch.
#   unfreeze  set the ruleset's enforcement to "disabled" so the branch falls
#             back to the repo's standing rules. The object is kept, ready to be
#             re-pointed at the next release branch.
#
# freeze re-points the same ruleset at the branch being released, so only that
# branch is affected; other release branches keep their normal rules.
#
# Required env:
#   GH_TOKEN            PAT or GitHub App token with Administration:write on
#                       INPUT_REPOSITORY. secrets.GITHUB_TOKEN cannot manage
#                       rulesets.
#   INPUT_OPERATION     "freeze" or "unfreeze".
#   INPUT_REPOSITORY    Target repo, owner/name.
#   INPUT_BRANCH        Release branch, e.g. "v0.36" or "release-4.11".
# Required for freeze:
#   INPUT_BYPASS_TEAM_ID  Numeric team id allowed to merge during the freeze
#                         (e.g. Eng-Tech-Leads). Find it with:
#                         gh api orgs/<org>/teams/<slug> --jq .id
# Optional:
#   INPUT_ENFORCEMENT   active | evaluate | disabled (default "active").
#                       evaluate = dry run: logs would-be blocks in the repo's
#                       ruleset insights but blocks nothing.
#   INPUT_RULESET_NAME  Override the ruleset name (default
#                       "release-branch-code-freeze").
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required (Administration:write on the target repo)}"
: "${INPUT_OPERATION:?operation required (freeze|unfreeze)}"
: "${INPUT_REPOSITORY:?repository required (owner/name)}"

REPO="$INPUT_REPOSITORY"
BRANCH="${INPUT_BRANCH:-}"
RULESET_NAME="${INPUT_RULESET_NAME:-release-branch-code-freeze}"

# Echo the id of the freeze ruleset (matched by name), or nothing.
find_ruleset_id() {
  gh api "repos/${REPO}/rulesets" |
    jq -r --arg n "$RULESET_NAME" 'map(select(.name == $n)) | (.[0].id // empty)'
}

write_output() {
  echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

case "$INPUT_OPERATION" in
  freeze)
    : "${INPUT_BRANCH:?branch required for freeze}"
    : "${INPUT_BYPASS_TEAM_ID:?bypass-team-id required for freeze}"
    if ! [[ "$INPUT_BYPASS_TEAM_ID" =~ ^[0-9]+$ ]]; then
      echo "::error::bypass-team-id must be numeric (got: ${INPUT_BYPASS_TEAM_ID})"
      exit 1
    fi
    ENFORCEMENT="${INPUT_ENFORCEMENT:-active}"
    case "$ENFORCEMENT" in
      active | evaluate | disabled) ;;
      *)
        echo "::error::enforcement must be active, evaluate, or disabled (got: ${ENFORCEMENT})"
        exit 1
        ;;
    esac

    # Build the payload with jq so branch names are JSON-escaped correctly.
    BODY=$(jq -n \
      --arg name "$RULESET_NAME" \
      --arg ref "refs/heads/${BRANCH}" \
      --arg enforcement "$ENFORCEMENT" \
      --argjson team_id "$INPUT_BYPASS_TEAM_ID" \
      '{
        name: $name,
        target: "branch",
        enforcement: $enforcement,
        conditions: { ref_name: { include: [ $ref ], exclude: [] } },
        rules: [ { type: "update" } ],
        bypass_actors: [ { actor_type: "Team", actor_id: $team_id, bypass_mode: "always" } ]
      }')

    RID="$(find_ruleset_id)"
    if [ -n "$RID" ]; then
      echo "::notice::updating ruleset ${RULESET_NAME} (id ${RID}) on ${REPO} -> ${BRANCH} (${ENFORCEMENT})"
      gh api -X PUT "repos/${REPO}/rulesets/${RID}" --input - <<<"$BODY" >/dev/null
    else
      echo "::notice::creating ruleset ${RULESET_NAME} on ${REPO} -> ${BRANCH} (${ENFORCEMENT})"
      RID="$(gh api -X POST "repos/${REPO}/rulesets" --input - <<<"$BODY" | jq -r '.id')"
    fi
    write_output "ruleset-id" "$RID"
    echo "::notice::freeze ${ENFORCEMENT}: only team ${INPUT_BYPASS_TEAM_ID} may merge into ${BRANCH} on ${REPO}"
    ;;
  unfreeze)
    RID="$(find_ruleset_id)"
    if [ -z "$RID" ]; then
      echo "::notice::no ruleset named ${RULESET_NAME} on ${REPO}; nothing to unfreeze"
      exit 0
    fi
    gh api -X PUT "repos/${REPO}/rulesets/${RID}" -f enforcement=disabled >/dev/null
    write_output "ruleset-id" "$RID"
    echo "::notice::unfreeze: ruleset ${RULESET_NAME} (id ${RID}) on ${REPO} set to disabled"
    ;;
  *)
    echo "::error::operation must be 'freeze' or 'unfreeze' (got: ${INPUT_OPERATION})"
    exit 1
    ;;
esac

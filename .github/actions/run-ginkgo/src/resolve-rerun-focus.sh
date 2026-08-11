#!/usr/bin/env bash
set -euo pipefail

# Exports GINKGO_FOCUS restricting the run to the previous attempt's failures.
#
# Required env:  GITHUB_ENV, GITHUB_OUTPUT
# Optional env:  RERUN_FAILED_ONLY, REPORTS_BUCKET, WORKFLOW_FILE, RUNNER_TEMP,
#                GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT
# Test seam:     RERUN_REPORTS_DIR - read reports from here instead of GCS

skip() {
  echo "::notice::Failed-only rerun not applied: $1 - running the full suite"
  echo "focused-rerun=false" >>"$GITHUB_OUTPUT"
  exit 0
}

[[ "${RERUN_FAILED_ONLY:-false}" == "true" ]] || exit 0

ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
[[ "$ATTEMPT" -gt 1 ]] || skip "first attempt of this run"

REPORTS_DIR="${RERUN_REPORTS_DIR:-}"
if [[ -z "$REPORTS_DIR" ]]; then
  [[ -n "${REPORTS_BUCKET:-}" && -n "${WORKFLOW_FILE:-}" ]] ||
    skip "reports-bucket and workflow-file are required to fetch the previous report"

  REPORTS_DIR="${RUNNER_TEMP:-/tmp}/ginkgo-previous-attempt"
  mkdir -p "$REPORTS_DIR"
  SRC="gs://${REPORTS_BUCKET}/${GITHUB_REPOSITORY}/${WORKFLOW_FILE}/${GITHUB_RUN_ID}/$((ATTEMPT - 1))"
  gcloud storage cp "${SRC}/*.json" "$REPORTS_DIR/" ||
    skip "no report from attempt $((ATTEMPT - 1)) at ${SRC}"
fi

shopt -s nullglob
REPORTS=("$REPORTS_DIR"/*.json)
[[ ${#REPORTS[@]} -gt 0 ]] || skip "no report files in ${REPORTS_DIR}"

# Rerun every spec sharing a failed spec's top-level container: the report drops
# IsInOrderedContainer, so an Ordered spec rerun alone would skip the siblings it needs.
# Each one is matched by its exact full text - a prefix match on the container would also
# pull in siblings like "Node Profiles" vs "Node Profiles - selection precedence".
RESULT=$(jq -sr '
  def esc: gsub("(?<c>[.\\\\+*?()|\\[\\]{}^$])"; "\\\(.c)");
  def container: [ .suite, ((.spec.ContainerHierarchyTexts // [])[0] // .spec.LeafNodeText) ];
  def fullText: [ .suite ] + (.spec.ContainerHierarchyTexts // []) + [ .spec.LeafNodeText ]
    | map(select(. != "")) | join(" ");

  [ .[] | .[]? | .SuiteDescription as $suite | (.SpecReports // [])[] | { suite: $suite, spec: . } ] as $all
  | [ $all[] | select(.spec.State | IN("passed", "skipped", "pending") | not) ] as $failed
  | if ($failed | length) == 0 then
      { focus: "", reason: "no failed specs in the previous report" }
    elif ($failed | any(.spec.LeafNodeType != "It")) then
      { focus: "", reason: "a suite setup/teardown node failed" }
    else
      ([ $failed[] | container ] | unique) as $containers
      | [ $all[] | select(.spec.LeafNodeType == "It" and (container | IN($containers[]))) ] as $rerun
      | { focus: ([ $rerun[] | "^" + (fullText | esc) + "$" ] | unique | join("|")),
          reason: "\($failed | length) failed spec(s), rerunning \($rerun | length) spec(s) across \($containers | length) top-level container(s)" }
    end
' "${REPORTS[@]}")

FOCUS=$(jq -r '.focus' <<<"$RESULT")
[[ -n "$FOCUS" ]] || skip "$(jq -r '.reason' <<<"$RESULT")"

echo "::notice::Rerunning only the specs that failed in attempt $((ATTEMPT - 1)): $(jq -r '.reason' <<<"$RESULT")"
echo "Focus: ${FOCUS}"
{
  echo "GINKGO_FOCUS<<GINKGO_FOCUS_EOF"
  echo "$FOCUS"
  echo "GINKGO_FOCUS_EOF"
} >>"$GITHUB_ENV"
echo "focused-rerun=true" >>"$GITHUB_OUTPUT"

#!/usr/bin/env bash
set -euo pipefail

# Emits a Ginkgo --focus restricting the run to the previous attempt's failures.
#
# Required env:  GITHUB_OUTPUT
# Optional env:  RERUN_FAILED_ONLY, UPLOAD_REPORT, REPORTS_BUCKET, WORKFLOW_FILE,
#                RUNNER_TEMP, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT
# Test seam:     RERUN_REPORTS_DIR - read reports from here instead of GCS
#
# Outputs:       focus, focused-rerun ('true'/'false', never unset)

skip() {
  echo "::notice::Failed-only rerun not applied: $1 - running the full suite"
  echo "focused-rerun=false" >>"$GITHUB_OUTPUT"
  exit 0
}

# The step has no if:, so focused-rerun is never empty. Callers that never opted in must
# not collect an annotation on every run.
if [[ "${RERUN_FAILED_ONLY:-false}" != "true" ]]; then
  echo "focused-rerun=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

if [[ -n "${UPLOAD_REPORT:-}" && "$UPLOAD_REPORT" != "true" ]]; then
  echo "::warning::rerun-failed-only needs upload-report: 'true' - without it no attempt publishes the report this reads, so reruns can never be narrowed"
fi

ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
[[ "$ATTEMPT" -gt 1 ]] || skip "first attempt of this run"

REPORTS_DIR="${RERUN_REPORTS_DIR:-}"
if [[ -z "$REPORTS_DIR" ]]; then
  [[ -n "${REPORTS_BUCKET:-}" && -n "${WORKFLOW_FILE:-}" ]] ||
    skip "reports-bucket and workflow-file are required to fetch the previous report"

  REPORTS_DIR="${RUNNER_TEMP:-/tmp}/ginkgo-previous-attempt"
  mkdir -p "$REPORTS_DIR"
  # Read path for the layout upload-report.sh writes - keep the two in sync.
  SRC="gs://${REPORTS_BUCKET}/${GITHUB_REPOSITORY}/${WORKFLOW_FILE}/${GITHUB_RUN_ID}/$((ATTEMPT - 1))"
  # A degraded bucket would otherwise hang the job up to its timeout-minutes.
  TIMEOUT=(timeout 300)
  command -v timeout >/dev/null || TIMEOUT=()
  "${TIMEOUT[@]}" gcloud storage cp "${SRC}/*.json" "$REPORTS_DIR/" ||
    skip "no report from attempt $((ATTEMPT - 1)) at ${SRC} (missing, unreadable or timed out)"
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

  [ .[] | .[]? ] as $suites
  | [ $suites[] | .SuiteDescription as $suite | (.SpecReports // [])[] | { suite: $suite, spec: . } ] as $all
  | [ $all[] | select(.spec.State | IN("passed", "skipped", "pending") | not) ] as $failed
  | ([ $suites[] | (.SpecialSuiteFailureReasons // [])[] ] | unique) as $abortReasons
  | if ($abortReasons | length) > 0 then
      # An interrupted, timed out or otherwise aborted suite marks its unexecuted specs
      # "skipped", indistinguishable from a deliberate skip, so they would never be rerun.
      { focus: "", reason: "the previous attempt did not complete (\($abortReasons | join("; ")))" }
    elif ($suites | any(.SuiteConfig.FailFast == true)) then
      { focus: "", reason: "the previous attempt ran with --fail-fast, which leaves unexecuted specs marked skipped" }
    elif ($failed | length) == 0 then
      { focus: "", reason: "no failed specs in the previous report" }
    elif ($failed | any(.spec.LeafNodeType != "It")) then
      { focus: "", reason: "a suite setup/teardown node failed" }
    else
      ([ $failed[] | container ] | unique) as $containers
      | [ $all[] | select(.spec.LeafNodeType == "It" and (container | IN($containers[]))) ] as $rerun
      | { focus: ([ $rerun[] | "^" + (fullText | esc) + "$" ] | unique | join("|")),
          containers: [ $containers[] | .[1] ],
          reason: "\($failed | length) failed spec(s), rerunning \($rerun | length) spec(s) across \($containers | length) top-level container(s)" }
    end
' "${REPORTS[@]}") || skip "could not parse the previous attempt's report(s) in ${REPORTS_DIR}"

FOCUS=$(jq -r '.focus' <<<"$RESULT")
REASON=$(jq -r '.reason' <<<"$RESULT")
[[ -n "$FOCUS" ]] || skip "$REASON"

# esc escapes regex metacharacters, not newlines: a spec text containing one would close
# the heredoc early and let the rest be parsed as workflow commands.
[[ "$FOCUS" != *$'\n'* ]] || skip "the previous report contains a spec whose text spans multiple lines"

echo "::notice::Rerunning only the specs that failed in attempt $((ATTEMPT - 1)): ${REASON}"
jq -r '"Rerunning these top-level containers:", (.containers[] | "  - " + .)' <<<"$RESULT"
echo "Focus: ${FOCUS}"
{
  echo "focus<<GINKGO_FOCUS_EOF"
  echo "$FOCUS"
  echo "GINKGO_FOCUS_EOF"
  echo "focused-rerun=true"
} >>"$GITHUB_OUTPUT"

#!/usr/bin/env bash
# Required env vars: REPORTS_BUCKET, WORKFLOW_FILE
# Required tools:    gh (with GH_TOKEN), gcloud (authenticated), jq
# GitHub-provided:   GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT,
#                    RUNNER_NAME, GITHUB_HEAD_REF, GITHUB_REF_NAME,
#                    GITHUB_SERVER_URL, GITHUB_WORKFLOW, GITHUB_JOB
set -euo pipefail

# Validate required env vars
: "${REPORTS_BUCKET:?REPORTS_BUCKET must be set}"
: "${WORKFLOW_FILE:?WORKFLOW_FILE must be set}"

# Validate required binaries
for bin in gh gcloud jq; do
  if ! command -v "$bin" &>/dev/null; then
    echo "::error::Required binary '$bin' not found in PATH — skipping GCS report upload"
    exit 1
  fi
done

if [ ! -f test-reports/report.json ]; then
  echo "::error::No Ginkgo report at test-reports/report.json — skipping GCS report upload"
  exit 0
fi

JOB_JSON=$(gh api \
  "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}/jobs" \
  --paginate \
  --jq ".jobs[] | select(.runner_name == \"${RUNNER_NAME}\")")

JOB_ID=$(echo "$JOB_JSON" | jq -r '.id')
STARTED_AT=$(echo "$JOB_JSON" | jq -r '.started_at')

if [ -z "$JOB_ID" ] || [ "$JOB_ID" = "null" ]; then
  echo "::error::Could not resolve numeric job_id for runner ${RUNNER_NAME} - skipping GCS report upload"
  exit 1
fi

FINISHED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
BRANCH="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME}}"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}"
DEST="gs://${REPORTS_BUCKET}/${GITHUB_REPOSITORY}/${WORKFLOW_FILE}/${GITHUB_RUN_ID}/${GITHUB_RUN_ATTEMPT}/${JOB_ID}.json"

gcloud storage cp test-reports/report.json "$DEST" \
  --custom-metadata="run_url=${RUN_URL},repository=${GITHUB_REPOSITORY},branch=${BRANCH},workflow_file=${WORKFLOW_FILE},workflow_name=${GITHUB_WORKFLOW},job_id=${JOB_ID},job_name=${GITHUB_JOB},run_attempt=${GITHUB_RUN_ATTEMPT},started_at=${STARTED_AT},finished_at=${FINISHED_AT}"

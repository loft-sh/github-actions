#!/usr/bin/env bats
# Tests for resolve-rerun-focus.sh

SCRIPT="$BATS_TEST_DIRNAME/../src/resolve-rerun-focus.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/rerun"

setup() {
  MOCK_DIR=$(mktemp -d)
  export GITHUB_ENV="$MOCK_DIR/env"
  export GITHUB_OUTPUT="$MOCK_DIR/output"
  touch "$GITHUB_ENV" "$GITHUB_OUTPUT"
  export RERUN_FAILED_ONLY=true
  export GITHUB_RUN_ATTEMPT=2
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# Helper: extract the GINKGO_FOCUS heredoc value from GITHUB_ENV
get_focus() {
  sed -n '/^GINKGO_FOCUS<<GINKGO_FOCUS_EOF$/,/^GINKGO_FOCUS_EOF$/{ /GINKGO_FOCUS_EOF$/d; p; }' "$GITHUB_ENV"
}

run_with() {
  RERUN_REPORTS_DIR="$FIXTURES/$1" run bash "$SCRIPT"
}

# Mocks gcloud to record its arguments and copy a fixture into the destination,
# so the GCS branch can be exercised without RERUN_REPORTS_DIR.
mock_gcloud() {
  local fixture="$1" exit_code="${2:-0}"
  MOCK_BIN="$MOCK_DIR/bin"
  mkdir -p "$MOCK_BIN"
  export MOCK_GCLOUD_ARGS="$MOCK_DIR/gcloud-args"
  cat >"$MOCK_BIN/gcloud" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$MOCK_GCLOUD_ARGS"
[ "$exit_code" -eq 0 ] || exit "$exit_code"
cp "$FIXTURES/$fixture"/*.json "\${@: -1}"
MOCK
  chmod +x "$MOCK_BIN/gcloud"
  export PATH="$MOCK_BIN:$PATH"
  export RUNNER_TEMP="$MOCK_DIR/runner-temp"
  export REPORTS_BUCKET="my-reports-bucket"
  export WORKFLOW_FILE="e2e-ginkgo.yaml"
  export GITHUB_REPOSITORY="loft-sh/loft-enterprise"
  export GITHUB_RUN_ID="42"
}

# --- guards: fall back to a full run ---

@test "does nothing when rerun-failed-only is not enabled" {
  RERUN_FAILED_ONLY=false run_with mixed-failures
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_ENV" ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "falls back to a full run on the first attempt" {
  GITHUB_RUN_ATTEMPT=1 run_with mixed-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"first attempt"* ]]
  [ -z "$(get_focus)" ]
  grep -q '^focused-rerun=false$' "$GITHUB_OUTPUT"
}

@test "falls back to a full run when the previous report has no failures" {
  run_with all-passed
  [ "$status" -eq 0 ]
  [[ "$output" == *"no failed specs"* ]]
  [ -z "$(get_focus)" ]
  grep -q '^focused-rerun=false$' "$GITHUB_OUTPUT"
}

@test "falls back to a full run when a suite setup node failed" {
  run_with setup-failure
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup/teardown node failed"* ]]
  [ -z "$(get_focus)" ]
  grep -q '^focused-rerun=false$' "$GITHUB_OUTPUT"
}

@test "falls back to a full run when the report directory is empty" {
  mkdir -p "$MOCK_DIR/empty"
  RERUN_REPORTS_DIR="$MOCK_DIR/empty" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no report files"* ]]
  grep -q '^focused-rerun=false$' "$GITHUB_OUTPUT"
}

@test "falls back to a full run when reports-bucket is missing" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reports-bucket and workflow-file are required"* ]]
  grep -q '^focused-rerun=false$' "$GITHUB_OUTPUT"
}

# --- focus construction ---

@test "anchors each spec's full text and escapes regex metacharacters" {
  run_with mixed-failures
  [ "$status" -eq 0 ]
  local focus
  focus="$(get_focus)"
  [[ "$focus" == *'^vCluster Platform E2E Suite Tenant \(a\) Sync syncs pods$'* ]]
}

@test "reruns the passing siblings sharing a failed spec's top-level container" {
  run_with mixed-failures
  [ "$status" -eq 0 ]
  local focus
  focus="$(get_focus)"
  [[ "$focus" == *'^vCluster Platform E2E Suite Tenant \(a\) Lifecycle creates a tenant cluster$'* ]]
}

@test "keeps the full nested hierarchy of a failed spec" {
  run_with mixed-failures
  [ "$status" -eq 0 ]
  local focus
  focus="$(get_focus)"
  [[ "$focus" == *'^vCluster Platform E2E Suite ArgoCD v2 template management parameter rendering renders parameters$'* ]]
}

@test "handles a failed spec that has no container" {
  run_with mixed-failures
  [ "$status" -eq 0 ]
  local focus
  focus="$(get_focus)"
  [[ "$focus" == *'^vCluster Platform E2E Suite top level spec with no container$'* ]]
}

@test "excludes containers whose specs all passed, skipped or are pending" {
  run_with mixed-failures
  [ "$status" -eq 0 ]
  local focus
  focus="$(get_focus)"
  [[ "$focus" != *"Sleep Mode"* ]]
  [[ "$focus" != *"Node Profiles"* ]]
}

@test "reports failed, rerun and container counts, and marks the run as focused" {
  run_with mixed-failures
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 failed spec(s), rerunning 4 spec(s) across 3 top-level container(s)"* ]]
  grep -q '^focused-rerun=true$' "$GITHUB_OUTPUT"
}

@test "merges reports across files and dedupes identical specs" {
  run_with multi-suite
  [ "$status" -eq 0 ]
  local focus
  focus="$(get_focus)"
  [[ "$focus" == *'^Suite A Alpha fails here$'* ]]
  [[ "$focus" == *'^Suite B Beta hangs$'* ]]
  # the same spec reported as both timedout and failed collapses into one alternative
  [ "$(awk -F'Suite B Beta hangs' '{print NF-1}' <<<"$focus")" -eq 1 ]
}

# --- fetching the previous attempt's report from GCS ---

@test "downloads the previous attempt's reports from the run's GCS prefix" {
  mock_gcloud mixed-failures
  GITHUB_RUN_ATTEMPT=3 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'gs://my-reports-bucket/loft-sh/loft-enterprise/e2e-ginkgo.yaml/42/2/\*.json' "$MOCK_GCLOUD_ARGS"
  grep -qx "$RUNNER_TEMP/ginkgo-previous-attempt/" "$MOCK_GCLOUD_ARGS"
}

@test "builds the focus from the downloaded reports" {
  mock_gcloud mixed-failures
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(get_focus)" == *'Tenant \(a\) Sync syncs pods'* ]]
  grep -q '^focused-rerun=true$' "$GITHUB_OUTPUT"
}

@test "falls back to a full run when the download fails" {
  mock_gcloud mixed-failures 1
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no report from attempt 1"* ]]
  [ -z "$(get_focus)" ]
  grep -q '^focused-rerun=false$' "$GITHUB_OUTPUT"
}

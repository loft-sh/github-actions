#!/usr/bin/env bats
# Tests for upload-report.sh

SCRIPT="$BATS_TEST_DIRNAME/../src/upload-report.sh"

setup() {
  MOCK_DIR=$(mktemp -d)
  MOCK_BIN="$MOCK_DIR/bin"
  mkdir -p "$MOCK_BIN"

  # Workspace root with a real report
  WORK_DIR="$MOCK_DIR/workspace"
  mkdir -p "$WORK_DIR/test-reports"
  echo '{"test":"data"}' > "$WORK_DIR/test-reports/report.json"

  # Common GitHub env vars
  export GITHUB_REPOSITORY="loft-sh/loft-enterprise"
  export GITHUB_RUN_ID="42"
  export GITHUB_RUN_ATTEMPT="1"
  export RUNNER_NAME="runner-1"
  export GITHUB_REF_NAME="main"
  export GITHUB_HEAD_REF=""
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_WORKFLOW="E2E Ginkgo Tests"
  export GITHUB_JOB="e2e-tests"

  # Script inputs
  export REPORTS_BUCKET="my-reports-bucket"
  export WORKFLOW_FILE="e2e-ginkgo.yaml"

  # Mock gh: returns a valid job JSON
  cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '{"id":99,"started_at":"2024-01-01T00:00:00Z"}'
MOCK
  chmod +x "$MOCK_BIN/gh"

  # Mock gcloud: records arguments
  export MOCK_GCLOUD_ARGS="$MOCK_DIR/gcloud-args"
  cat > "$MOCK_BIN/gcloud" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$MOCK_DIR/gcloud-args"
MOCK
  chmod +x "$MOCK_BIN/gcloud"

  # Mock date: deterministic timestamp
  cat > "$MOCK_BIN/date" <<'MOCK'
#!/usr/bin/env bash
echo "2024-01-01T12:00:00Z"
MOCK
  chmod +x "$MOCK_BIN/date"

  # Mock jq: thin wrapper around the real jq
  # (real jq is expected to be on PATH; mock bin prepended so mocks take priority)

  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# --- upload-report flag: required inputs ---
# The upload-report input gates whether action steps run (action.yml).
# When they do run, REPORTS_BUCKET and WORKFLOW_FILE must be provided.
# These tests document what happens when a caller sets upload-report=true
# but omits one of the required inputs.

@test "exits non-zero when REPORTS_BUCKET is unset (upload-report=true but bucket not set)" {
  unset REPORTS_BUCKET
  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REPORTS_BUCKET"* ]]
}

@test "exits non-zero when WORKFLOW_FILE is unset (upload-report=true but workflow-file not set)" {
  unset WORKFLOW_FILE
  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WORKFLOW_FILE"* ]]
}

# --- Binary validation ---

@test "exits 1 with error when gh is not in PATH" {
  rm "$MOCK_BIN/gh"
  # Use a bare PATH (mock bin + bash only) so the system gh is not reachable
  local bare_bin
  bare_bin=$(mktemp -d)
  ln -s "$(command -v bash)" "$bare_bin/bash"
  cd "$MOCK_DIR/workspace"
  PATH="$MOCK_BIN:$bare_bin" run bash "$SCRIPT"
  rm -rf "$bare_bin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"'gh' not found"* ]]
}

@test "exits 1 with error when gcloud is not in PATH" {
  rm "$MOCK_BIN/gcloud"
  local bare_bin
  bare_bin=$(mktemp -d)
  ln -s "$(command -v bash)" "$bare_bin/bash"
  cd "$MOCK_DIR/workspace"
  PATH="$MOCK_BIN:$bare_bin" run bash "$SCRIPT"
  rm -rf "$bare_bin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"'gcloud' not found"* ]]
}

# --- Missing report ---

@test "exits 0 with error when report.json is absent" {
  cd "$MOCK_DIR/workspace"
  rm test-reports/report.json
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"skipping GCS report upload"* ]]
}

# --- Bad job ID ---

@test "exits 1 with error when gh api returns null job id" {
  cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '{"id":null,"started_at":"2024-01-01T00:00:00Z"}'
MOCK
  chmod +x "$MOCK_BIN/gh"

  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"Could not resolve numeric job_id"* ]]
}

@test "exits 1 with error when gh api returns empty job id" {
  cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '{"id":"","started_at":"2024-01-01T00:00:00Z"}'
MOCK
  chmod +x "$MOCK_BIN/gh"

  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}

# --- Happy path ---

@test "calls gcloud storage cp with correct destination" {
  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  EXPECTED_DEST="gs://my-reports-bucket/loft-sh/loft-enterprise/e2e-ginkgo.yaml/42/1/99.json"
  grep -qF "$EXPECTED_DEST" "$MOCK_DIR/gcloud-args"
}

@test "calls gcloud storage cp with correct source file" {
  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "test-reports/report.json" "$MOCK_DIR/gcloud-args"
}

@test "metadata includes run_url" {
  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "run_url=https://github.com/loft-sh/loft-enterprise/actions/runs/42/attempts/1" "$MOCK_DIR/gcloud-args"
}

@test "metadata uses GITHUB_HEAD_REF as branch when set" {
  export GITHUB_HEAD_REF="feature/my-branch"
  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "branch=feature/my-branch" "$MOCK_DIR/gcloud-args"
}

@test "metadata falls back to GITHUB_REF_NAME when GITHUB_HEAD_REF is empty" {
  export GITHUB_HEAD_REF=""
  export GITHUB_REF_NAME="main"
  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "branch=main" "$MOCK_DIR/gcloud-args"
}

@test "metadata includes workflow_file" {
  cd "$MOCK_DIR/workspace"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF "workflow_file=e2e-ginkgo.yaml" "$MOCK_DIR/gcloud-args"
}

#!/usr/bin/env bats
# Tests for cleanup-head-charts.sh
#
# Uses a mock curl to simulate ChartMuseum API responses without network access.

SCRIPT="$BATS_TEST_DIRNAME/../cleanup-head-charts.sh"

setup() {
  export CHART_MUSEUM_URL="https://charts.example.com"
  export CHART_MUSEUM_USER="user"
  export CHART_MUSEUM_PASSWORD="pass"

  # Create a temp directory for the mock curl
  MOCK_DIR=$(mktemp -d)
  export MOCK_CURL_RESPONSE_FILE="$MOCK_DIR/curl_response"
  export MOCK_CURL_EXIT_CODE_FILE="$MOCK_DIR/curl_exit_code"
  export MOCK_CURL_DELETE_LOG="$MOCK_DIR/curl_delete_log"
  export MOCK_CURL_DELETE_FAIL_VERSIONS="$MOCK_DIR/curl_delete_fail"

  # Default: curl succeeds
  echo "0" > "$MOCK_CURL_EXIT_CODE_FILE"
  touch "$MOCK_CURL_DELETE_LOG"
  touch "$MOCK_CURL_DELETE_FAIL_VERSIONS"

  # Create the mock curl script
  cat > "$MOCK_DIR/curl" <<'MOCK'
#!/usr/bin/env bash
# Mock curl for testing cleanup-head-charts.sh
#
# GET requests return the contents of MOCK_CURL_RESPONSE_FILE.
# DELETE requests log the URL to MOCK_CURL_DELETE_LOG and optionally
# fail for versions listed in MOCK_CURL_DELETE_FAIL_VERSIONS.

IS_DELETE=false
for arg in "$@"; do
  if [ "$arg" = "DELETE" ]; then
    IS_DELETE=true
  fi
done

if [ "$IS_DELETE" = "true" ]; then
  # Extract the version from the last URL argument
  URL="${*: -1}"
  VERSION="${URL##*/}"
  echo "$VERSION" >> "$MOCK_CURL_DELETE_LOG"

  # Check if this version should fail
  if grep -qx "$VERSION" "$MOCK_CURL_DELETE_FAIL_VERSIONS" 2>/dev/null; then
    exit 1
  fi
  echo '{"deleted":true}'
  exit 0
fi

# GET request
EXIT_CODE=$(cat "$MOCK_CURL_EXIT_CODE_FILE")
if [ "$EXIT_CODE" -ne 0 ]; then
  exit "$EXIT_CODE"
fi
cat "$MOCK_CURL_RESPONSE_FILE"
MOCK
  chmod +x "$MOCK_DIR/curl"

  # Prepend mock to PATH
  export PATH="$MOCK_DIR:$PATH"
}

teardown() {
  rm -rf "$MOCK_DIR"
}

# Helper: generate a ChartMuseum JSON response with N versions.
# Versions are numbered 0.0.1 through 0.0.N with ascending timestamps.
generate_versions() {
  local count=$1
  local include_latest=${2:-false}
  local json="["
  local sep=""

  if [ "$include_latest" = "true" ]; then
    json="${json}${sep}{\"version\":\"0.0.0-latest\",\"created\":\"2000-01-01T00:00:00Z\"}"
    sep=","
  fi

  for i in $(seq 1 "$count"); do
    local ts
    ts=$(printf "2025-01-%02dT00:00:00Z" "$i")
    json="${json}${sep}{\"version\":\"0.0.$i\",\"created\":\"$ts\"}"
    sep=","
  done

  echo "${json}]"
}

# --- Tests ---

@test "fails when chart-name argument is missing" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "no cleanup when version count is below max" {
  generate_versions 3 > "$MOCK_CURL_RESPONSE_FILE"

  run bash "$SCRIPT" "test-chart" 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 3 head chart versions"* ]]
  [[ "$output" == *"no cleanup needed"* ]]
}

@test "no cleanup when version count equals max" {
  generate_versions 5 > "$MOCK_CURL_RESPONSE_FILE"

  run bash "$SCRIPT" "test-chart" 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 5 head chart versions"* ]]
  [[ "$output" == *"no cleanup needed"* ]]
}

@test "deletes oldest versions when count exceeds max" {
  generate_versions 5 > "$MOCK_CURL_RESPONSE_FILE"

  run bash "$SCRIPT" "test-chart" 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleting 2 old versions"* ]]
  [[ "$output" == *"deleted 2/2 versions"* ]]

  # Versions 0.0.1 and 0.0.2 are oldest and should be deleted
  [ "$(wc -l < "$MOCK_CURL_DELETE_LOG")" -eq 2 ]
  grep -q "0.0.1" "$MOCK_CURL_DELETE_LOG"
  grep -q "0.0.2" "$MOCK_CURL_DELETE_LOG"
}

@test "dry-run lists versions without deleting" {
  generate_versions 5 > "$MOCK_CURL_RESPONSE_FILE"

  run bash "$SCRIPT" "test-chart" 3 true
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"Would delete 2 old versions"* ]]

  # No actual deletions
  [ ! -s "$MOCK_CURL_DELETE_LOG" ]
}

@test "excludes 0.0.0-latest from version count and deletion" {
  generate_versions 3 true > "$MOCK_CURL_RESPONSE_FILE"

  run bash "$SCRIPT" "test-chart" 50
  [ "$status" -eq 0 ]
  # Should count 3, not 4 (0.0.0-latest excluded)
  [[ "$output" == *"Found 3 head chart versions (excluding '0.0.0-latest')"* ]]
  [[ "$output" == *"no cleanup needed"* ]]
}

@test "exits with error when API fetch fails" {
  echo "22" > "$MOCK_CURL_EXIT_CODE_FILE"

  run bash "$SCRIPT" "test-chart"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch chart versions"* ]]
}

@test "continues when individual version delete fails" {
  generate_versions 5 > "$MOCK_CURL_RESPONSE_FILE"
  # Make 0.0.1 fail to delete
  echo "0.0.1" > "$MOCK_CURL_DELETE_FAIL_VERSIONS"

  run bash "$SCRIPT" "test-chart" 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"Failed to delete 0.0.1"* ]]
  [[ "$output" == *"Successfully deleted 0.0.2"* ]]
  [[ "$output" == *"deleted 1/2 versions"* ]]
}

@test "handles empty chart response" {
  echo "[]" > "$MOCK_CURL_RESPONSE_FILE"

  run bash "$SCRIPT" "test-chart" 50
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 0 head chart versions"* ]]
  [[ "$output" == *"no cleanup needed"* ]]
}

@test "max-versions defaults to 50" {
  generate_versions 3 > "$MOCK_CURL_RESPONSE_FILE"

  run bash "$SCRIPT" "test-chart"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cleanup needed (keeping last 50)"* ]]
}

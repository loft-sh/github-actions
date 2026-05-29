#!/usr/bin/env bats
# Decision-table coverage for should-update.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/should-update.sh"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/deployment.yaml"

setup() {
  export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"
  # Work on a copy so the fixture is never mutated.
  MANIFEST="$(mktemp)"; cp "$FIXTURE" "$MANIFEST"
}
teardown() { rm -f "$GITHUB_OUTPUT" "$MANIFEST"; }

run_script() {
  # args: new_version is_stable environment [manifest] [container]
  run env \
    MANIFEST_PATH="${4:-$MANIFEST}" CONTAINER_NAME="${5:-revops-events-api}" \
    NEW_VERSION="$1" IS_STABLE="$2" ENVIRONMENT="$3" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
}

assert_kv() {
  local want="$1=$2" actual
  actual=$(grep "^$1=" "$GITHUB_OUTPUT" | tail -n1)
  [ "$actual" = "$want" ] || { echo "want: $want"; echo "got:  $actual"; cat "$GITHUB_OUTPUT"; return 1; }
}

@test "newer stable version → should_update true" {
  run_script 0.2.0 true staging
  [ "$status" -eq 0 ]; assert_kv should_update true; assert_kv current_tag v0.1.0
}

@test "same version → should_update false" {
  run_script 0.1.0 true staging
  [ "$status" -eq 0 ]; assert_kv should_update false
}

@test "older version → should_update false (no downgrade)" {
  run_script 0.0.9 true staging
  [ "$status" -eq 0 ]; assert_kv should_update false
}

@test "pre-release to prod → skipped" {
  run_script 0.2.0-rc1 false prod
  [ "$status" -eq 0 ]; assert_kv should_update false
  assert_kv reason "pre-release skipped for prod"
}

@test "pre-release to staging → allowed when newer" {
  run_script 0.2.0-rc1 false staging
  [ "$status" -eq 0 ]; assert_kv should_update true
}

@test "missing manifest → false with reason" {
  run_script 0.2.0 true staging /no/such/file.yaml
  [ "$status" -eq 0 ]; assert_kv should_update false
}

@test "unknown container → false" {
  run_script 0.2.0 true staging "$MANIFEST" not-a-container
  [ "$status" -eq 0 ]; assert_kv should_update false
}

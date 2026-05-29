#!/usr/bin/env bats
# Coverage for resolve-version.sh: tag normalisation, stability, app name.

SCRIPT="$BATS_TEST_DIRNAME/../src/resolve-version.sh"

setup() { export GITHUB_OUTPUT; GITHUB_OUTPUT="$(mktemp)"; }
teardown() { rm -f "$GITHUB_OUTPUT"; }

run_script() {
  run env RAW_TAG="$1" IMAGE_REPO="$2" GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
}

assert_kv() {
  local want="$1=$2" actual
  actual=$(grep "^$1=" "$GITHUB_OUTPUT" | tail -n1)
  [ "$actual" = "$want" ] || { echo "want: $want"; echo "got:  $actual"; cat "$GITHUB_OUTPUT"; return 1; }
}

@test "v-prefixed stable tag" {
  run_script 'v0.2.0' 'ghcr.io/loft-sh/revops-events-api'
  [ "$status" -eq 0 ]
  assert_kv new_tag v0.2.0
  assert_kv new_version 0.2.0
  assert_kv is_stable true
  assert_kv app_name revops-events-api
}

@test "bare stable tag (no v)" {
  run_script '1.4.2' 'ghcr.io/loft-sh/app'
  [ "$status" -eq 0 ]
  assert_kv new_tag 1.4.2
  assert_kv new_version 1.4.2
  assert_kv is_stable true
}

@test "pre-release tag is not stable" {
  run_script 'v1.0.0-rc1' 'ghcr.io/loft-sh/app'
  [ "$status" -eq 0 ]
  assert_kv is_stable false
  assert_kv new_version 1.0.0-rc1
}

@test "missing RAW_TAG fails" {
  run env IMAGE_REPO='ghcr.io/loft-sh/app' GITHUB_OUTPUT="$GITHUB_OUTPUT" "$SCRIPT"
  [ "$status" -ne 0 ]
}

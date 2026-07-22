#!/usr/bin/env bats
# Tests for action.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/action.sh"

load gh_mock
load docker_mock

setup() {
  setup_gh_mock
  setup_docker_mock
  export GH_TOKEN="fake-token"
  export INPUT_VERSION="v0.37.1"
  export INPUT_IMAGES='[{"image":"ghcr.io/loft-sh/vcluster-pro"},{"image":"ghcr.io/loft-sh/vcluster-pro","suffix":"-fips"}]'
  export INPUT_OSS_REPO="loft-sh/vcluster"
  export INPUT_DRY_RUN="false"
  export GH_MOCK_KNOWN_RELEASES="loft-sh/vcluster:v0.37.1"
}

teardown() {
  teardown_gh_mock
  teardown_docker_mock
}

@test "happy path -> retags latest/major/minor for every image entry, including suffix" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  grep -qF 'CREATE ghcr.io/loft-sh/vcluster-pro:latest ghcr.io/loft-sh/vcluster-pro:v0.37.1' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/loft-sh/vcluster-pro:0 ghcr.io/loft-sh/vcluster-pro:v0.37.1' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/loft-sh/vcluster-pro:0.37 ghcr.io/loft-sh/vcluster-pro:v0.37.1' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/loft-sh/vcluster-pro:latest-fips ghcr.io/loft-sh/vcluster-pro:v0.37.1-fips' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/loft-sh/vcluster-pro:0-fips ghcr.io/loft-sh/vcluster-pro:v0.37.1-fips' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/loft-sh/vcluster-pro:0.37-fips ghcr.io/loft-sh/vcluster-pro:v0.37.1-fips' "$DOCKER_MOCK_CALLS"
  [ "$(wc -l < "$DOCKER_MOCK_CALLS")" -eq 6 ]
}

@test "happy path -> promotes the paired oss-repo release" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  grep -qF 'VIEW loft-sh/vcluster v0.37.1' "$GH_MOCK_CALLS"
  grep -qF -- 'EDIT loft-sh/vcluster v0.37.1 --prerelease=false --latest' "$GH_MOCK_CALLS"
}

@test "non-stable version (has a suffix) -> no-op, no docker or gh calls" {
  export INPUT_VERSION="v0.37.1-rc.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$DOCKER_MOCK_CALLS" ]
  [ ! -s "$GH_MOCK_CALLS" ]
}

@test "oss-repo has no matching release -> warns, still retags docker, does not edit" {
  export GH_MOCK_KNOWN_RELEASES=""
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no v0.37.1 release found on loft-sh/vcluster"* ]]
  grep -qF 'VIEW loft-sh/vcluster v0.37.1' "$GH_MOCK_CALLS"
  ! grep -q '^EDIT ' "$GH_MOCK_CALLS"
  [ "$(wc -l < "$DOCKER_MOCK_CALLS")" -eq 6 ]
}

@test "empty oss-repo -> skips the paired release entirely" {
  export INPUT_OSS_REPO=""
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_MOCK_CALLS" ]
}

@test "dry-run -> prints planned retags, makes no real docker calls" {
  export INPUT_DRY_RUN="true"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] docker buildx imagetools create --tag ghcr.io/loft-sh/vcluster-pro:latest ghcr.io/loft-sh/vcluster-pro:v0.37.1"* ]]
  [ ! -s "$DOCKER_MOCK_CALLS" ]
}

@test "dry-run -> still reads oss-repo state but does not edit it" {
  export INPUT_DRY_RUN="true"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF 'VIEW loft-sh/vcluster v0.37.1' "$GH_MOCK_CALLS"
  ! grep -q '^EDIT ' "$GH_MOCK_CALLS"
}

@test "missing image field in an entry -> fails before any docker call" {
  export INPUT_IMAGES='[{"image":"ghcr.io/loft-sh/vcluster-pro"},{"suffix":"-fips"}]'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$DOCKER_MOCK_CALLS" ]
}

@test "malformed images JSON -> fails fast, no calls" {
  export INPUT_IMAGES='not json'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$DOCKER_MOCK_CALLS" ]
}

@test "empty images array -> fails fast" {
  export INPUT_IMAGES='[]'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "missing GH_TOKEN -> fail fast, no calls" {
  unset GH_TOKEN
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$DOCKER_MOCK_CALLS" ]
}

@test "missing version -> fail fast" {
  unset INPUT_VERSION
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "docker push failure -> non-zero exit" {
  export DOCKER_MOCK_FAIL=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

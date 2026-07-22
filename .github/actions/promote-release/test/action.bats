#!/usr/bin/env bats
# Tests for action.sh.
#
# Fixtures use an obviously-fake version (v9.9.9, not a real vcluster-pro
# release line) and fake images/repos (example-org/...), never real
# ghcr.io/loft-sh/* names or plausible real version numbers, so nobody
# mistakes test data for a real artifact.

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../src/action.sh"

load gh_mock
load docker_mock

# Sets GH_MOCK_RELEASE_LIST_<repo> so is_latest_stable() sees a release
# history for that repo (see gh_mock.bash for the varname sanitization).
set_release_list() {
  local repo="$1" json="$2"
  local varname
  varname="GH_MOCK_RELEASE_LIST_$(printf '%s' "$repo" | tr -c 'A-Za-z0-9' '_')"
  export "$varname=$json"
}

setup() {
  setup_gh_mock
  setup_docker_mock
  export GH_TOKEN="fake-token"
  export GITHUB_REPOSITORY="example-org/example-caller-repo"
  export INPUT_VERSION="v9.9.9"
  export INPUT_IMAGES='[{"image":"ghcr.io/example-org/example-image"},{"image":"ghcr.io/example-org/example-image","suffix":"-fips"}]'
  export INPUT_OSS_REPO="example-org/example-repo"
  export INPUT_DRY_RUN="false"
  export GH_MOCK_KNOWN_RELEASES="example-org/example-repo:v9.9.9"
}

teardown() {
  teardown_gh_mock
  teardown_docker_mock
}

@test "happy path -> retags latest/major/minor for every image entry, including suffix" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  grep -qF 'CREATE ghcr.io/example-org/example-image:latest ghcr.io/example-org/example-image:v9.9.9' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/example-org/example-image:9 ghcr.io/example-org/example-image:v9.9.9' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/example-org/example-image:9.9 ghcr.io/example-org/example-image:v9.9.9' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/example-org/example-image:latest-fips ghcr.io/example-org/example-image:v9.9.9-fips' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/example-org/example-image:9-fips ghcr.io/example-org/example-image:v9.9.9-fips' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/example-org/example-image:9.9-fips ghcr.io/example-org/example-image:v9.9.9-fips' "$DOCKER_MOCK_CALLS"
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 6 ]
}

@test "happy path -> promotes the paired oss-repo release" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  grep -qF 'VIEW example-org/example-repo v9.9.9' "$GH_MOCK_CALLS"
  grep -qF -- 'EDIT example-org/example-repo v9.9.9 --prerelease=false --latest' "$GH_MOCK_CALLS"
}

@test "non-stable version (has a suffix) -> no-op, no docker or gh calls" {
  export INPUT_VERSION="v9.9.9-rc.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$DOCKER_MOCK_CALLS" ]
  [ ! -s "$GH_MOCK_CALLS" ]
}

@test "oss-repo has no matching release -> warns, still retags docker, does not edit" {
  export GH_MOCK_KNOWN_RELEASES=""
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no v9.9.9 release found on example-org/example-repo"* ]]
  grep -qF 'VIEW example-org/example-repo v9.9.9' "$GH_MOCK_CALLS"
  run ! grep -q '^EDIT ' "$GH_MOCK_CALLS"
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 6 ]
}

@test "empty oss-repo -> skips the paired release entirely" {
  export INPUT_OSS_REPO=""
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # A "LIST" call for GITHUB_REPOSITORY's own backport check is expected;
  # what must NOT happen is any view/edit call touching an oss-repo.
  run ! grep -q '^VIEW \|^EDIT ' "$GH_MOCK_CALLS"
}

@test "dry-run -> prints planned retags, makes no real docker calls" {
  export INPUT_DRY_RUN="true"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] docker buildx imagetools create --tag ghcr.io/example-org/example-image:latest ghcr.io/example-org/example-image:v9.9.9"* ]]
  [ ! -s "$DOCKER_MOCK_CALLS" ]
}

@test "dry-run -> still reads oss-repo state but does not edit it" {
  export INPUT_DRY_RUN="true"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF 'VIEW example-org/example-repo v9.9.9' "$GH_MOCK_CALLS"
  run ! grep -q '^EDIT ' "$GH_MOCK_CALLS"
}

@test "backport on caller repo -> skips :latest/:major, still advances :major.minor" {
  set_release_list "$GITHUB_REPOSITORY" '[{"tagName":"v10.0.0","isPrerelease":false}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the newest stable release on example-org/example-caller-repo"* ]]

  grep -qF 'CREATE ghcr.io/example-org/example-image:9.9 ghcr.io/example-org/example-image:v9.9.9' "$DOCKER_MOCK_CALLS"
  grep -qF 'CREATE ghcr.io/example-org/example-image:9.9-fips ghcr.io/example-org/example-image:v9.9.9-fips' "$DOCKER_MOCK_CALLS"
  run ! grep -qF ':latest ' "$DOCKER_MOCK_CALLS"
  run ! grep -qF ':9 ' "$DOCKER_MOCK_CALLS"
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 2 ]

  # A different repo's history (oss-repo) is unaffected by the caller repo's:
  # the paired release still gets --latest.
  grep -qF -- 'EDIT example-org/example-repo v9.9.9 --prerelease=false --latest' "$GH_MOCK_CALLS"
}

@test "backport on oss-repo -> paired release unsets prerelease but omits --latest" {
  set_release_list "$INPUT_OSS_REPO" '[{"tagName":"v10.0.0","isPrerelease":false}]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the newest stable release on example-org/example-repo"* ]]

  grep -qF -- 'EDIT example-org/example-repo v9.9.9 --prerelease=false' "$GH_MOCK_CALLS"
  run ! grep -qF -- '--latest' "$GH_MOCK_CALLS"

  # The caller repo's own history is unaffected: docker tags fully advance.
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 6 ]
}

@test "gh release list failure -> fails closed, does not treat it as no prior releases" {
  export GH_MOCK_LIST_FAIL=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to list releases on example-org/example-caller-repo"* ]]
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 0 ]
}

@test "missing source manifest for a suffix variant -> fails before any create call" {
  export DOCKER_MOCK_MISSING="ghcr.io/example-org/example-image:v9.9.9-fips"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source manifest ghcr.io/example-org/example-image:v9.9.9-fips does not exist"* ]]
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 0 ]
}

@test "missing image field in an entry -> fails before any create call" {
  export INPUT_IMAGES='[{"image":"ghcr.io/example-org/example-image"},{"suffix":"-fips"}]'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 0 ]
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

@test "missing GITHUB_REPOSITORY -> fail fast, no calls" {
  unset GITHUB_REPOSITORY
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -s "$DOCKER_MOCK_CALLS" ]
}

@test "missing version -> fail fast" {
  unset INPUT_VERSION
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "docker push failure -> aborts on the first create call" {
  export DOCKER_MOCK_FAIL=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 1 ]
}

@test "gh release edit failure -> warns but does not fail the run (docker retags already done)" {
  export GH_MOCK_FAIL=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::gh release edit failed for example-org/example-repo@v9.9.9"* ]]
  [ "$(grep -c '^CREATE ' "$DOCKER_MOCK_CALLS")" -eq 6 ]
}

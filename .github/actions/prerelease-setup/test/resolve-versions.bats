#!/usr/bin/env bats
# Tests for resolve-versions.sh. Stubs `curl` (see curl_mock.bash); uses the
# real jq and sort so the ordering logic is exercised end to end.

SCRIPT="$BATS_TEST_DIRNAME/../src/resolve-versions.sh"

load curl_mock

setup() {
  setup_curl_mock
  export GH_TOKEN="fake-token"
  export STANDALONE_VCLUSTER_VERSION_INPUT=""
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT=""
  export PLATFORM_BASE_VERSION_INPUT=""
  export PLATFORM_RC_VERSION_INPUT=""
  export GITHUB_OUTPUT="$MOCK_DIR/output"
  export GITHUB_ENV="$MOCK_DIR/env"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_ENV"

  # Rows are deliberately NOT in publish order, so a test only passes if the
  # code sorts by published_at itself. 0.36.1 has shipped, so 0.36.1-rc.4 is
  # the newest pre-release by publish time but must not be chosen.
  set_releases vcluster 1 "[
    $(release v0.37.0-alpha.1 true 2026-07-29T22:36:43Z),
    $(release v0.36.1-rc.4    true 2026-07-31T13:43:34Z),
    $(release v0.35.3-rc.2    true 2026-07-29T23:19:04Z),
    $(release v0.34.7-rc.2    true 2026-07-28T13:13:40Z),
    $(release v0.36.1         false 2026-08-03T10:00:00Z),
    $(release v0.35.2         false 2026-07-01T10:00:00Z),
    $(release v0.34.6         false 2026-06-01T10:00:00Z),
    $(release v0.36.0         false 2026-07-20T10:00:00Z)
  ]"
  # 4.11.1 has shipped; 4.12.0-alpha.2 has not.
  set_releases loft-enterprise 1 "[
    $(release v4.11.1-rc.1    true 2026-07-29T14:57:24Z),
    $(release v4.12.0-alpha.2 true 2026-07-28T13:36:00Z),
    $(release v4.11.1         false 2026-08-02T10:00:00Z),
    $(release v4.11.0         false 2026-07-20T10:00:00Z),
    $(release v4.10.6         false 2026-07-22T10:00:00Z),
    $(release v4.10.5         false 2026-07-01T10:00:00Z)
  ]"
}

teardown() { teardown_curl_mock; }

out() { grep "^$1=" "$GITHUB_OUTPUT" | cut -d= -f2-; }

# --- base resolution: the bug this action shipped -----------------------------

@test "a maintenance target takes the highest release below it, not the newest overall" {
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.35.3-rc.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-version)" = "0.35.2" ]
}

@test "an older maintenance target does the same" {
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.34.7-rc.2"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-version)" = "0.34.6" ]
}

@test "a brand new minor with no release of its own still gets a base" {
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.37.0-alpha.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-version)" = "0.36.1" ]
}

@test "a maintenance RC published after a newer GA skips its own released patch" {
  export PLATFORM_RC_VERSION_INPUT="4.10.6-rc.2"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.36.1-rc.3"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # 4.10.6 exists and is NEWER than 4.10.6-rc.2, so the base must be 4.10.5
  [ "$(out platform-base-version)" = "4.10.5" ]
}

# --- target resolution -------------------------------------------------------

@test "an empty target skips a pre-release whose release already shipped" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # 0.36.1-rc.4 is the newest by publish time but 0.36.1 is out, so 0.35.3-rc.2 wins
  [ "$(out standalone-vcluster-upgrade-version)" = "0.35.3-rc.2" ]
  [ "$(out standalone-vcluster-version)" = "0.35.2" ]
  # 4.11.1-rc.1 is newest by publish time but 4.11.1 is out, so 4.12.0-alpha.2 wins
  [ "$(out platform-rc-version)" = "4.12.0-alpha.2" ]
}

@test "the target is chosen by publish time, not by list order or version" {
  # highest version first in the list, but its release has shipped
  set_releases vcluster 1 "[
    $(release v0.40.0-rc.1 true 2026-01-01T00:00:00Z),
    $(release v0.39.0-rc.1 true 2026-09-01T00:00:00Z),
    $(release v0.40.0      false 2026-02-01T00:00:00Z),
    $(release v0.38.0      false 2025-12-01T00:00:00Z)
  ]"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.39.0-rc.1" ]
}

@test "-next builds are never chosen as a target" {
  set_releases vcluster 1 "[
    $(release v0.38.0-next.internal.4 true),
    $(release v0.37.0-alpha.1 true),
    $(release v0.36.0 false)
  ]"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.37.0-alpha.1" ]
}

@test "tags that are not versions are ignored" {
  set_releases vcluster 1 "[
    $(release untagged-6162a828673fc8cf true),
    $(release v0.37.0-alpha.1 true),
    $(release v0.36.0 false)
  ]"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.37.0-alpha.1" ]
}

# --- explicit inputs win -----------------------------------------------------

@test "explicitly supplied versions are used as given" {
  export STANDALONE_VCLUSTER_VERSION_INPUT="v0.35.0"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="v0.35.1"
  export PLATFORM_BASE_VERSION_INPUT="v4.11.0"
  export PLATFORM_RC_VERSION_INPUT="v4.11.1-rc.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-version)" = "0.35.0" ]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.35.1" ]
  [ "$(out platform-base-version)" = "4.11.0" ]
  [ "$(out platform-rc-version)" = "4.11.1-rc.1" ]
}

# --- rejections --------------------------------------------------------------

@test "a backwards vCluster pair is rejected" {
  export STANDALONE_VCLUSTER_VERSION_INPUT="0.36.0"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.35.3-rc.1"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not newer than base"* ]]
}

@test "a backwards platform pair is rejected" {
  export PLATFORM_BASE_VERSION_INPUT="4.11.0"
  export PLATFORM_RC_VERSION_INPUT="4.10.6-rc.2"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.36.1-rc.3"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not newer than platform-base-version"* ]]
}

@test "identical versions are rejected" {
  export STANDALONE_VCLUSTER_VERSION_INPUT="0.36.0"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.36.0"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must differ"* ]]
}

@test "a pre-release is treated as older than its own release" {
  export STANDALONE_VCLUSTER_VERSION_INPUT="0.36.0-rc.7"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.36.0"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-version)" = "0.36.0-rc.7" ]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.36.0" ]
}

@test "the reverse of that pair is rejected" {
  export STANDALONE_VCLUSTER_VERSION_INPUT="0.36.0"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.36.0-rc.7"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not newer than base"* ]]
}

@test "a malformed version is rejected" {
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="not-a-version"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid standalone-vcluster-upgrade-version"* ]]
}

@test "a failing API call fails the step rather than reporting no releases" {
  export CURL_MOCK_FAIL=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to list releases"* ]]
}

@test "no stable below the target is an error, not an empty base" {
  set_releases vcluster 1 "[ $(release v0.37.0-alpha.1 true) ]"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no stable vCluster release below"* ]]
}

# --- reading the listing ---------------------------------------------------

@test "a target on page two is still found" {
  set_releases vcluster 1 "[ $(filler 98), $(release v0.36.0 false), $(release v0.35.2 false) ]"
  set_releases vcluster 2 "[ $(release v0.37.0-alpha.1 true 2026-07-29T22:36:43Z) ]"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.37.0-alpha.1" ]
}

@test "a higher base on page two beats a lower one on page one" {
  set_releases vcluster 1 "[ $(filler 98), $(release v0.35.9-rc.1 true), $(release v0.35.2 false) ]"
  set_releases vcluster 2 "[ $(release v0.35.8 false) ]"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.35.9-rc.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-version)" = "0.35.8" ]
}

@test "each listing is read once, and a short page ends it" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(pages_read vcluster)" -eq 1 ]
  [ "$(pages_read loft-enterprise)" -eq 1 ]
}

@test "the page limit is not mentioned on a normal run" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"exceeded"* ]]
}

@test "exceeding the page limit fails instead of answering from a partial list" {
  export RELEASE_PAGE_LIMIT=1
  set_releases vcluster 1 "[ $(filler 97), $(release v0.37.0-alpha.1 true 2026-07-29T22:36:43Z), $(release v0.36.1 false), $(release v0.36.0 false) ]"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to resolve from a partial list"* ]]
}

@test "a failure on a later page is reported as an API failure" {
  export CURL_MOCK_FAIL_AFTER=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to list releases"* ]]
  [[ "$output" != *"no stable vCluster release below"* ]]
}

# --- exported values ---------------------------------------------------------

@test "resolved versions are mirrored to GITHUB_ENV" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "^STANDALONE_VCLUSTER_VERSION=0.35.2$" "$GITHUB_ENV"
  grep -q "^STANDALONE_VCLUSTER_UPGRADE_VERSION=0.35.3-rc.2$" "$GITHUB_ENV"
  grep -q "^PLATFORM_BASE_VERSION=4.11.1$" "$GITHUB_ENV"
  grep -q "^PLATFORM_RC_VERSION=4.12.0-alpha.2$" "$GITHUB_ENV"
  grep -q "^DEFAULT_VCLUSTER_CHART_VERSION=0.35.2$" "$GITHUB_ENV"
}

# --- environment contract ----------------------------------------------------

@test "runs with none of the four version inputs set" {
  unset STANDALONE_VCLUSTER_VERSION_INPUT
  unset STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT
  unset PLATFORM_BASE_VERSION_INPUT
  unset PLATFORM_RC_VERSION_INPUT
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.35.3-rc.2" ]
}

@test "a non-numeric page limit fails with a clear message" {
  export RELEASE_PAGE_LIMIT=abc
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"RELEASE_PAGE_LIMIT must be a positive integer, got: abc"* ]]
  [[ "$output" != *"integer expected"* ]]
}

@test "a zero page limit is rejected" {
  export RELEASE_PAGE_LIMIT=0
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a positive integer"* ]]
}

# --- malformed API responses -------------------------------------------------

@test "a 200 response that is not an array fails fast with our own message" {
  export CURL_MOCK_BODY='<html>proxy error</html>'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected response listing releases"* ]]
  [[ "$output" != *"parse error"* ]]
  [[ "$output" != *"integer expression expected"* ]]
  # must fail on the first page, not page on to the limit
  [ "$(pages_read vcluster)" -eq 1 ]
}

@test "a JSON object body fails the same way" {
  export CURL_MOCK_BODY='{"message":"Bad credentials"}'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected response listing releases"* ]]
}

# --- publish-time edge cases -------------------------------------------------

@test "a null published_at never wins the target" {
  set_releases vcluster 1 "[
    {\"tag_name\":\"v0.30.0-rc.1\",\"prerelease\":true,\"draft\":false,\"published_at\":null},
    $(release v0.37.0-alpha.1 true 2026-07-01T00:00:00Z),
    $(release v0.36.0 false 2026-06-01T00:00:00Z)
  ]"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.37.0-alpha.1" ]
}

@test "a published_at tie breaks on semver, not string order" {
  set_releases vcluster 1 "[
    $(release v0.35.9-rc.1  true 2026-07-01T00:00:00Z),
    $(release v0.35.10-rc.1 true 2026-07-01T00:00:00Z),
    $(release v0.35.8 false 2026-06-01T00:00:00Z)
  ]"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-upgrade-version)" = "0.35.10-rc.1" ]
}

# --- exit-status hygiene -----------------------------------------------------

@test "a listing that ends above the target still resolves" {
  # the last stable read is NOT below the target, which used to end the run
  # with exit 1 and no message
  set_releases vcluster 1 "[
    $(release v0.35.2 false 2026-07-01T10:00:00Z),
    $(release v0.36.0 false 2026-07-20T10:00:00Z)
  ]"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.35.3-rc.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out standalone-vcluster-version)" = "0.35.2" ]
}

@test "a listing whose only stable is above the target reports it" {
  set_releases vcluster 1 "[ $(release v0.36.0 false 2026-07-20T10:00:00Z) ]"
  export STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT="0.35.3-rc.1"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no stable vCluster release below 0.35.3-rc.1"* ]]
}

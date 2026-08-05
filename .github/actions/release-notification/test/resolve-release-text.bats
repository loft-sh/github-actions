#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../resolve-release-text.sh"

setup() {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  export TARGET_REPO="example-org/private-product"
  export VERSION="v9.9.9"
  export PREVIOUS_TAG="v9.9.8"
  export PAIRED_REPO=""
  export IS_PRERELEASE="false"
  export NEEDS_PROMOTION="false"
  export PROMOTE_WORKFLOW="promote-release.yaml"
}

output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

@test "default caller gets no label field and the original single-repo links" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value label_field)" = "" ]
  [ "$(output_value changelog_text)" = '<https://github.com/example-org/private-product/compare/v9.9.8...v9.9.9|View Full Changelog>' ]
  [ "$(output_value release_text)" = '<https://github.com/example-org/private-product/releases/tag/v9.9.9|View Release>' ]
}

@test "pre-release renders the opt-in GitHub label field" {
  export IS_PRERELEASE="true"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value label_field)" = '- {"type": "mrkdwn", "text": "*GitHub label:*\nPre-release"}' ]
}

@test "promotion reminder describes the newest-release gate accurately" {
  export NEEDS_PROMOTION="true"
  export PROMOTE_WORKFLOW="ship-stable.yaml"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  label="$(output_value label_field)"
  [[ "$label" == *'<https://github.com/example-org/private-product/actions/workflows/ship-stable.yaml|Promote it>'* ]]
  [[ "$label" == *'when this is the newest release'* ]]
  [[ "$label" != *'to move Latest, the moving image tags'* ]]
}

@test "promotion reminder takes precedence when both state flags are true" {
  export NEEDS_PROMOTION="true"
  export IS_PRERELEASE="true"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(output_value label_field)" == *'`None` - not Latest yet'* ]]
}

@test "paired repository link labels match their own URL hosts" {
  export PAIRED_REPO="example-org/public-product"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value changelog_text)" = '<https://github.com/example-org/private-product/compare/v9.9.8...v9.9.9|example-org/private-product> | <https://github.com/example-org/public-product/compare/v9.9.8...v9.9.9|example-org/public-product>' ]
  [ "$(output_value release_text)" = 'Releases: <https://github.com/example-org/private-product/releases/tag/v9.9.9|example-org/private-product> | <https://github.com/example-org/public-product/releases/tag/v9.9.9|example-org/public-product>' ]
}

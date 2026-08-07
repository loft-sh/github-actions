#!/usr/bin/env bats
# Tests for resolve-github-release.sh
#
# Every test runs against a configurable `gh` stub on PATH, so no real API
# call is made and no test needs a token. The stub counts `gh api` calls so
# tests can assert the pass-through path never touches the API.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/resolve-github-release.sh"

  STUB_DIR="$(mktemp -d)"
  PATH="${STUB_DIR}:${PATH}"
  export GH_STUB_COUNT_FILE="${STUB_DIR}/count"

  export INPUT_REPO="loft-sh/vcluster"
  export INPUT_VERSION="latest"
  export GITHUB_OUTPUT="${STUB_DIR}/github_output"
  export GITHUB_STEP_SUMMARY="${STUB_DIR}/github_step_summary"

  install_gh_stub
}

teardown() {
  rm -rf "$STUB_DIR"
}

# A single configurable `gh` stub, driven per-test by env:
#   GH_STUB_TAG           tag_name the latest-release lookup returns (default v0.30.0)
#   GH_STUB_NO_RELEASE=1  repo has no published release. Real `gh api` behaviour,
#                         captured from the CLI: the endpoint 404s and gh exits
#                         non-zero printing the HTTP error to stderr. It does NOT
#                         return 200 with an empty tag_name.
#   GH_STUB_API_ERROR=1   transport-level failure (non-404 stderr), kept distinct
#                         from the 404 so absent-vs-failed stays testable.
install_gh_stub() {
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
set -u
n=$(( $(cat "${GH_STUB_COUNT_FILE}" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"${GH_STUB_COUNT_FILE}"

if [[ "${GH_STUB_API_ERROR:-}" == "1" ]]; then
  echo "error connecting to api.github.com" >&2
  exit 1
fi
if [[ "${GH_STUB_NO_RELEASE:-}" == "1" ]]; then
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
echo "${GH_STUB_TAG:-v0.30.0}"
EOF
  chmod +x "${STUB_DIR}/gh"
}

api_calls() {
  cat "${GH_STUB_COUNT_FILE}" 2>/dev/null || echo 0
}

# emitted_tag prints the tag value written to GITHUB_OUTPUT. emit writes the
# heredoc-delimiter form (tag<<DELIM / value / DELIM), so read the line after
# the key marker rather than a key=value pair.
emitted_tag() {
  sed -n '/^tag<</{n;p;}' "$GITHUB_OUTPUT"
}

no_tag_emitted() {
  ! grep -qE '^tag(=|<<)' "$GITHUB_OUTPUT" 2>/dev/null
}

@test "latest resolves via the API and emits the tag" {
  export GH_STUB_TAG="v0.31.2"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(emitted_tag)" = "v0.31.2" ]
  [ "$(api_calls)" -eq 1 ]
}

@test "main resolves the same way as latest" {
  export INPUT_VERSION="main"
  export GH_STUB_TAG="v0.31.2"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(emitted_tag)" = "v0.31.2" ]
  [ "$(api_calls)" -eq 1 ]
}

@test "an explicit tag passes through without calling the API" {
  export INPUT_VERSION="v0.29.0-rc.1"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(emitted_tag)" = "v0.29.0-rc.1" ]
  [ "$(api_calls)" -eq 0 ]
}

@test "the resolved tag is recorded in the step summary" {
  export GH_STUB_TAG="v0.31.2"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q 'loft-sh/vcluster release used: `v0.31.2`' "$GITHUB_STEP_SUMMARY"
}

@test "a transport error fails with the gh stderr, without emitting a tag" {
  export GH_STUB_API_ERROR=1

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not resolve the latest release"* ]]
  [[ "$output" == *"error connecting to api.github.com"* ]]
  no_tag_emitted
}

@test "a repo with no releases (404) fails with the specific message, without emitting a tag" {
  export GH_STUB_NO_RELEASE=1

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"has no published releases"* ]]
  no_tag_emitted
}

@test "a version containing newlines cannot forge extra output pairs" {
  export INPUT_VERSION=$'v1.2.3\nmalicious-output=pwned\nanother=1'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  # The whole payload must be contained in a single tag<<DELIM ... DELIM block:
  # exactly 5 lines (marker, 3 value lines, closing delimiter), so the forged
  # key=value lines are heredoc body the runner treats as part of tag's value,
  # not standalone output pairs.
  first=$(sed -n '1p' "$GITHUB_OUTPUT")
  [[ "$first" == "tag<<"* ]]
  delim="${first#tag<<}"
  [ "$(wc -l < "$GITHUB_OUTPUT")" -eq 5 ]
  [ "$(sed -n '5p' "$GITHUB_OUTPUT")" = "$delim" ]
  [ "$(sed -n '2,4p' "$GITHUB_OUTPUT")" = "$INPUT_VERSION" ]
}

@test "missing INPUT_REPO fails" {
  unset INPUT_REPO

  run "$SCRIPT"

  [ "$status" -ne 0 ]
}

@test "missing INPUT_VERSION fails" {
  unset INPUT_VERSION

  run "$SCRIPT"

  [ "$status" -ne 0 ]
}

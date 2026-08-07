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
#   GH_STUB_TAG        tag_name the latest-release lookup returns (default v0.30.0)
#   GH_STUB_NO_RELEASE=1  lookup succeeds but tag_name is empty (no releases)
#   GH_STUB_API_ERROR=1   lookup fails with a transport error
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
  # `--jq '.tag_name // empty'` on a tag-less payload prints nothing.
  exit 0
fi
echo "${GH_STUB_TAG:-v0.30.0}"
EOF
  chmod +x "${STUB_DIR}/gh"
}

api_calls() {
  cat "${GH_STUB_COUNT_FILE}" 2>/dev/null || echo 0
}

@test "latest resolves via the API and emits the tag" {
  export GH_STUB_TAG="v0.31.2"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q '^tag=v0.31.2$' "$GITHUB_OUTPUT"
  [ "$(api_calls)" -eq 1 ]
}

@test "main resolves the same way as latest" {
  export INPUT_VERSION="main"
  export GH_STUB_TAG="v0.31.2"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q '^tag=v0.31.2$' "$GITHUB_OUTPUT"
  [ "$(api_calls)" -eq 1 ]
}

@test "an explicit tag passes through without calling the API" {
  export INPUT_VERSION="v0.29.0-rc.1"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q '^tag=v0.29.0-rc.1$' "$GITHUB_OUTPUT"
  [ "$(api_calls)" -eq 0 ]
}

@test "the resolved tag is recorded in the step summary" {
  export GH_STUB_TAG="v0.31.2"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q 'loft-sh/vcluster release used: `v0.31.2`' "$GITHUB_STEP_SUMMARY"
}

@test "an API error fails without emitting a tag" {
  export GH_STUB_API_ERROR=1

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not resolve the latest release"* ]]
  ! grep -q '^tag=' "$GITHUB_OUTPUT" 2>/dev/null
}

@test "a repo with no releases fails without emitting a tag" {
  export GH_STUB_NO_RELEASE=1

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"has no published releases"* ]]
  ! grep -q '^tag=' "$GITHUB_OUTPUT" 2>/dev/null
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

#!/usr/bin/env bats
# Tests for resolve-github-release.sh
#
# Every test runs against a configurable `gh` stub on PATH, so no real API
# call is made and no test needs a token. The stub counts `gh api` calls so
# tests can assert the pass-through path never touches the API, and records
# every argument list so tests can assert which endpoint was asked.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/resolve-github-release.sh"

  STUB_DIR="$(mktemp -d)"
  PATH="${STUB_DIR}:${PATH}"
  export GH_STUB_COUNT_FILE="${STUB_DIR}/count"
  export GH_STUB_ARGS_FILE="${STUB_DIR}/args"

  export INPUT_REPO="loft-sh/vcluster"
  export INPUT_VERSION="latest"
  export GITHUB_OUTPUT="${STUB_DIR}/github_output"
  export GITHUB_STEP_SUMMARY="${STUB_DIR}/github_step_summary"

  install_gh_stub
}

teardown() {
  rm -rf "$STUB_DIR"
}

# A single configurable `gh` stub, driven per-test by env. It routes on the
# requested endpoint, because the script asks two different ones: the
# latest-release lookup, and — only to classify a 404 — the repo itself.
#   GH_STUB_TAG              tag_name the latest-release lookup returns (default v0.30.0)
#   GH_STUB_EMPTY_TAG=1      a 200 whose payload has no tag_name, so `--jq
#                            '.tag_name // empty'` yields an empty string
#   GH_STUB_NO_RELEASE=1     repo exists but has no published release. Real
#                            `gh api` behaviour, captured from the CLI: the
#                            endpoint 404s and gh exits non-zero printing the
#                            HTTP error to stderr. It does NOT return 200 with
#                            an empty tag_name.
#   GH_STUB_REPO_INVISIBLE=1 repo name is wrong, or the token cannot read it:
#                            the repo endpoint 404s too, which is the only
#                            thing separating this from GH_STUB_NO_RELEASE.
#   GH_STUB_API_ERROR=1      transport-level failure, kept distinct from the
#                            404 so absent-vs-failed stays testable. Its
#                            stderr is multi-line, as gh's really is.
install_gh_stub() {
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${GH_STUB_ARGS_FILE}"
n=$(( $(cat "${GH_STUB_COUNT_FILE}" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"${GH_STUB_COUNT_FILE}"

case "$*" in
  *releases/latest*)
    if [[ "${GH_STUB_API_ERROR:-}" == "1" ]]; then
      printf 'error connecting to api.github.com\n::warning::forged\ncheck your internet connection\n' >&2
      exit 1
    fi
    if [[ "${GH_STUB_NO_RELEASE:-}" == "1" || "${GH_STUB_REPO_INVISIBLE:-}" == "1" ]]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    if [[ "${GH_STUB_EMPTY_TAG:-}" == "1" ]]; then
      exit 0
    fi
    echo "${GH_STUB_TAG:-v0.30.0}"
    ;;
  *)
    # The repo endpoint, asked only to classify a 404.
    if [[ "${GH_STUB_REPO_INVISIBLE:-}" == "1" ]]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    echo "loft-sh/vcluster"
    ;;
esac
EOF
  chmod +x "${STUB_DIR}/gh"
}

api_calls() {
  cat "${GH_STUB_COUNT_FILE}" 2>/dev/null || echo 0
}

api_args() {
  cat "${GH_STUB_ARGS_FILE}" 2>/dev/null || true
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

@test "latest asks the latest-release endpoint of the requested repo" {
  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$(api_args)" == *"repos/loft-sh/vcluster/releases/latest"* ]]
  [[ "$(api_args)" == *".tag_name // empty"* ]]
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

@test "a padded, mixed-case latest still resolves instead of passing through" {
  export INPUT_VERSION=$'  LATEST \n'
  export GH_STUB_TAG="v0.31.2"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(emitted_tag)" = "v0.31.2" ]
  [ "$(api_calls)" -eq 1 ]
}

@test "an explicit tag is emitted without its surrounding whitespace" {
  export INPUT_VERSION=$'\tv0.29.0\n'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(emitted_tag)" = "v0.29.0" ]
  [ "$(api_calls)" -eq 0 ]
}

@test "the resolved tag is recorded in the step summary as its own list item" {
  export GH_STUB_TAG="v0.31.2"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q '^- loft-sh/vcluster release used: `v0.31.2`$' "$GITHUB_STEP_SUMMARY"
}

@test "two resolutions in one job stay two summary lines" {
  export GH_STUB_TAG="v0.31.2"
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  export INPUT_REPO="loft-sh/loft-enterprise"
  export INPUT_VERSION="v4.4.0"
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(grep -c '^- .* release used: ' "$GITHUB_STEP_SUMMARY")" -eq 2 ]
}

@test "a transport error fails with the gh stderr on one line, without emitting a tag" {
  export GH_STUB_API_ERROR=1

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not resolve the latest release"* ]]
  [[ "$output" == *"error connecting to api.github.com"* ]]
  # The whole multi-line stderr is folded into the single annotation, so a
  # `::`-prefixed line in an API error body cannot become a workflow command.
  [[ "$output" == *"check your internet connection"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'could not resolve')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^::warning::forged')" -eq 0 ]
  no_tag_emitted
}

@test "a repo with no releases (404) fails with the specific message, without emitting a tag" {
  export GH_STUB_NO_RELEASE=1

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"has no published releases"* ]]
  no_tag_emitted
}

@test "a repo the token cannot see is not reported as having no releases" {
  export GH_STUB_REPO_INVISIBLE=1

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"is not visible to this token"* ]]
  [[ "$output" != *"has no published releases"* ]]
  no_tag_emitted
}

@test "a release without a tag_name fails instead of emitting an empty tag" {
  export GH_STUB_EMPTY_TAG=1

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"has no tag_name"* ]]
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

# Unpredictability is not observable from outside the script, so this pins what
# is: the shape the entropy tiers all produce, and that it is redrawn per run.
# The tier that supplied it is the script's business.
@test "the output delimiter is 32 hex characters and is redrawn per run" {
  export INPUT_VERSION="v1.2.3"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  first_delim=$(sed -n '1p' "$GITHUB_OUTPUT")

  : >"$GITHUB_OUTPUT"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  second_delim=$(sed -n '1p' "$GITHUB_OUTPUT")

  [ "$first_delim" != "$second_delim" ]
  [[ "$first_delim" =~ ^tag\<\<GH_OUTPUT_EOF_[0-9a-f]{32}$ ]]
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

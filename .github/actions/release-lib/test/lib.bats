#!/usr/bin/env bats
# Tests for release-lib/lib.sh on its own, with a line-branch convention other
# than platform-release's. The routing and probes are covered in depth by the
# platform-release suite; this one pins the contract a second caller relies on:
# every branch name comes from the sourcing script's globals.

setup() {
  source "${BATS_TEST_DIRNAME}/../lib.sh"
  DEFAULT_BRANCH="trunk"
  LINE_BRANCH_FORMAT="v%s.%s"
  LINE_BRANCH_PATTERN='^v[0-9]+\.[0-9]+$'
}

@test "derive_line: follows LINE_BRANCH_FORMAT" {
  run derive_line "v0.37.2-rc.1"
  [ "$status" -eq 0 ]
  [ "$output" = "v0.37" ]
}

@test "is_feature_branch: the default and line branches come from the globals" {
  run is_feature_branch trunk
  [ "$status" -eq 1 ]
  run is_feature_branch v0.37
  [ "$status" -eq 1 ]
  # main is an ordinary branch name once it is not the default.
  run is_feature_branch main
  [ "$status" -eq 0 ]
  run is_feature_branch release-4.11
  [ "$status" -eq 0 ]
}

@test "resolve_target: alpha goes to DEFAULT_BRANCH and names it when refusing" {
  run resolve_target alpha "" v0.37
  [ "$status" -eq 0 ]
  [ "$output" = "trunk" ]
  run resolve_target alpha main v0.37
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from trunk only, not 'main'"* ]]
}

@test "resolve_target: rc and stable route to the line branch they are given" {
  run resolve_target rc v0.37 v0.37
  [ "$status" -eq 0 ]
  [ "$output" = "v0.37" ]
  run resolve_target stable "" v0.37
  [ "$status" -eq 0 ]
  [ "$output" = "v0.37" ]
}

@test "validate_version: the semver gate does not depend on the caller" {
  run validate_version "v0.37.02"
  [ "$status" -ne 0 ]
  run validate_version "v0.37.0-rc."
  [ "$status" -ne 0 ]
  run validate_version "v0.37.0-rc.1"
  [ "$status" -eq 0 ]
}

@test "classify_suffix: a dashed unrouted flavor is not an alpha" {
  run classify_suffix "v0.37.0-devpod-alpha.1"
  [ "$status" -ne 0 ]
}

@test "a caller that forgets a global fails loudly under set -u" {
  # The lib defines no defaults, so a missing global must not fall back to an
  # empty string and route everything to "".
  # The exit code for an unbound variable varies by bash version, so the inner
  # shell's status is reported rather than pinned.
  run bash -c '( set -u; source "$1"; is_feature_branch main ) 2>&1; echo "rc=$?"' _ "${BATS_TEST_DIRNAME}/../lib.sh"
  [[ "$output" == *"DEFAULT_BRANCH"* ]]
  [[ "$output" != *"rc=0"* ]]
}

@test "run_captured: stdout and stderr land in separate variables" {
  local out err
  run_captured out err bash -c 'echo body; echo notice >&2'
  [ "$out" = "body" ]
  [ "$err" = "notice" ]
}

@test "run_captured: the command's exit status is returned and stdin passes through" {
  local out err rc=0
  run_captured out err bash -c 'cat; echo failed >&2; exit 3' <<<"from stdin" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$out" = "from stdin" ]
  [ "$err" = "failed" ]
}

# stub_gh <body> - put a `gh` on PATH that runs <body> with the call's args, and
# logs every call to $GH_LOG.
stub_gh() {
  STUB_DIR="$(mktemp -d)"
  GH_LOG="${STUB_DIR}/log"
  export GH_LOG
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$GH_LOG"\n%s\n' "$1" >"${STUB_DIR}/gh"
  chmod +x "${STUB_DIR}/gh"
  PATH="${STUB_DIR}:${PATH}"
}

@test "tag_runs: queries the workflow it is given, under both tag spellings" {
  stub_gh 'printf "{\"workflow_runs\":[{\"id\":7,\"head_sha\":\"abc\",\"status\":\"queued\",\"conclusion\":null}]}\n" | jq -r "${@: -1}"'
  local runs
  tag_runs runs org/repo build.yaml v0.37.2
  grep -q 'workflows/build.yaml/runs?branch=v0.37.2&' "$GH_LOG"
  grep -q 'workflows/build.yaml/runs?branch=refs/tags/v0.37.2&' "$GH_LOG"
  # The same run under both queries is counted once.
  [ "$runs" = "7 abc queued none" ]
  [ "$(count_runs_at "$runs" abc)" -eq 1 ]
}

@test "tag_runs: an error-shaped body is an unknown answer, not no runs" {
  stub_gh 'printf "{\"message\":\"Server Error\"}\n" | jq -r "${@: -1}"'
  local runs
  run tag_runs runs org/repo build.yaml v0.37.2
  [ "$status" -ne 0 ]
}

@test "require_tag_on_target: a gone line branch named by the globals is refused" {
  stub_gh 'echo "HTTP/2.0 404 Not Found"; exit 1'
  run require_tag_on_target org/repo v0.37 v0.37.2 abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"branch 'v0.37' not found"* ]]
  run require_tag_on_target org/repo trunk v0.37.2 abc
  [ "$status" -ne 0 ]
}

@test "require_tag_on_target: a gone feature branch only warns" {
  # release-4.11 is a feature branch under this caller's convention.
  stub_gh 'echo "HTTP/2.0 404 Not Found"; exit 1'
  run require_tag_on_target org/repo release-4.11 v0.37.2-next.1 abc
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::branch 'release-4.11' no longer exists"* ]]
}

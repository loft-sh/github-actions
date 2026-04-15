#!/usr/bin/env bats
# Tests for run.sh
#
# Stubs `helm` so we can assert on the package/push argument vector and
# fixture out search/pull responses. Uses the real `yq` and `jq` so the
# Chart.yaml/values.yaml edits and JSON parsing are validated end-to-end.

SCRIPT="$BATS_TEST_DIRNAME/../run.sh"

setup() {
  # The script uses mikefarah/yq syntax (`strenv()`, `-i` for in-place).
  # Skip if a different yq (e.g. the Python kislyuk/yq) is on PATH.
  if ! command -v yq >/dev/null || ! yq --version 2>&1 | grep -q "mikefarah"; then
    skip "mikefarah/yq is not installed (the Python yq is incompatible)"
  fi

  TEST_DIR=$(mktemp -d)
  export TEST_DIR

  MOCK_DIR="$TEST_DIR/mock"
  mkdir -p "$MOCK_DIR"

  export HELM_CALLS="$TEST_DIR/helm_calls"
  export HELM_PACKAGE_DIR="$TEST_DIR/helm_packages"
  export HELM_SEARCH_OUTPUT="$TEST_DIR/helm_search_output"
  export HELM_SEARCH_EXIT="$TEST_DIR/helm_search_exit"
  export HELM_PULL_FAIL="$TEST_DIR/helm_pull_fail"

  : > "$HELM_CALLS"
  echo "0" > "$HELM_SEARCH_EXIT"
  : > "$HELM_PULL_FAIL"

  # Stub helm:
  #   - record every invocation as a tab-separated line in HELM_CALLS
  #   - `helm package <dir> --version V [--app-version A] --destination D`
  #     creates an empty file at D/<chart-name>-V.tgz so the script's
  #     subsequent cm-push call sees a real path
  #   - `helm search repo` emits HELM_SEARCH_OUTPUT (or exits with
  #     HELM_SEARCH_EXIT on non-zero)
  #   - `helm pull` creates an empty tarball so cm-push has something to
  #     reference, unless HELM_PULL_FAIL is non-empty
  cat > "$MOCK_DIR/helm" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HELM_CALLS"

case "$1" in
  package)
    chart_dir=""
    version=""
    dest=""
    while [ $# -gt 0 ]; do
      case "$1" in
        package)         shift ;;
        --version)       version="$2"; shift 2 ;;
        --app-version)   shift 2 ;;
        --destination)   dest="$2"; shift 2 ;;
        *)               chart_dir="$1"; shift ;;
      esac
    done
    name=$(yq -r '.name' "$chart_dir/Chart.yaml")
    mkdir -p "$dest"
    : > "$dest/${name}-${version}.tgz"
    ;;
  search)
    if [ "$(cat "$HELM_SEARCH_EXIT")" != "0" ]; then
      exit "$(cat "$HELM_SEARCH_EXIT")"
    fi
    cat "$HELM_SEARCH_OUTPUT"
    ;;
  pull)
    if [ -s "$HELM_PULL_FAIL" ]; then
      exit 1
    fi
    chart_ref=""
    version=""
    dest=""
    while [ $# -gt 0 ]; do
      case "$1" in
        pull)           shift ;;
        --version)      version="$2"; shift 2 ;;
        --destination)  dest="$2"; shift 2 ;;
        *)              chart_ref="$1"; shift ;;
      esac
    done
    name="${chart_ref#chartmuseum/}"
    mkdir -p "$dest"
    : > "$dest/${name}-${version}.tgz"
    ;;
esac
exit 0
MOCK
  chmod +x "$MOCK_DIR/helm"

  export PATH="$MOCK_DIR:$PATH"

  # Standard chart fixture
  CHART_DIR="$TEST_DIR/chart"
  mkdir -p "$CHART_DIR"
  cat > "$CHART_DIR/Chart.yaml" <<'YAML'
apiVersion: v2
name: original-name
description: original description
version: 0.0.0
appVersion: 0.0.0
YAML
  cat > "$CHART_DIR/values.yaml" <<'YAML'
product: original
foo:
  bar: baz
YAML

  # Default env vars
  export CHART_DIRECTORY="$CHART_DIR"
  export CHART_NAME="my-chart"
  export CHART_VERSIONS_JSON='["1.2.3"]'
  export CHART_MUSEUM_URL="https://charts.example.com/"
  export CHART_MUSEUM_USER="user"
  export CHART_MUSEUM_PASSWORD="pass"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Helper: count helm calls matching a fixed-string pattern. Uses `-e --` so
# patterns starting with `-` are treated as text, not flags.
helm_call_count() {
  grep -c -F -e "$1" -- "$HELM_CALLS" || true
}

# --- Required env validation ------------------------------------------------

@test "fails when CHART_DIRECTORY is missing" {
  unset CHART_DIRECTORY
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when CHART_NAME is missing" {
  unset CHART_NAME
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when CHART_VERSIONS_JSON is missing" {
  unset CHART_VERSIONS_JSON
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when CHART_MUSEUM_URL is missing" {
  unset CHART_MUSEUM_URL
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails when Chart.yaml does not exist" {
  rm "$CHART_DIRECTORY/Chart.yaml"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

# --- CHART_VERSIONS_JSON parsing --------------------------------------------

@test "fails on invalid JSON" {
  CHART_VERSIONS_JSON='not-json' run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "fails on empty array" {
  CHART_VERSIONS_JSON='[]' run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at least one version"* ]]
}

# --- Chart.yaml edits -------------------------------------------------------

@test "sets .name in Chart.yaml" {
  CHART_NAME="my-renamed-chart" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.name' "$CHART_DIRECTORY/Chart.yaml")" = "my-renamed-chart" ]
}

@test "sets .description in Chart.yaml when CHART_DESCRIPTION provided" {
  CHART_DESCRIPTION="My new description" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.description' "$CHART_DIRECTORY/Chart.yaml")" = "My new description" ]
}

@test "leaves .description unchanged when CHART_DESCRIPTION not provided" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.description' "$CHART_DIRECTORY/Chart.yaml")" = "original description" ]
}

# --- values.yaml edits ------------------------------------------------------

@test "applies single VALUES_EDITS entry" {
  VALUES_EDITS="product=vcluster-pro" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.product' "$CHART_DIRECTORY/values.yaml")" = "vcluster-pro" ]
}

@test "applies multiple VALUES_EDITS entries" {
  VALUES_EDITS="product=vcluster-pro
foo.bar=qux" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.product' "$CHART_DIRECTORY/values.yaml")" = "vcluster-pro" ]
  [ "$(yq -r '.foo.bar' "$CHART_DIRECTORY/values.yaml")" = "qux" ]
}

@test "fails on malformed VALUES_EDITS entry" {
  VALUES_EDITS="no-equals-sign" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jsonpath=value"* ]]
}

@test "fails when VALUES_EDITS provided but values.yaml missing" {
  rm "$CHART_DIRECTORY/values.yaml"
  VALUES_EDITS="product=vcluster-pro" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"values.yaml does not exist"* ]]
}

@test "ignores blank lines in VALUES_EDITS" {
  VALUES_EDITS="
product=vcluster-pro

" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.product' "$CHART_DIRECTORY/values.yaml")" = "vcluster-pro" ]
}

# --- helm package -----------------------------------------------------------

@test "packages once per version" {
  CHART_VERSIONS_JSON='["1.2.3","0.0.0-latest"]' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(helm_call_count "package $CHART_DIRECTORY --version 1.2.3")" -eq 1 ]
  [ "$(helm_call_count "package $CHART_DIRECTORY --version 0.0.0-latest")" -eq 1 ]
}

@test "passes --app-version when APP_VERSION is set" {
  APP_VERSION="head-abc123" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(helm_call_count "--app-version head-abc123")" -eq 1 ]
}

@test "omits --app-version when APP_VERSION is empty" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(helm_call_count "--app-version")" -eq 0 ]
}

# --- helm cm-push -----------------------------------------------------------

@test "pushes one tarball per version with chart-name-derived filename" {
  CHART_NAME="vcluster-head"
  CHART_VERSIONS_JSON='["0.0.0-latest","0.0.0-abc1234"]' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(helm_call_count "cm-push --force")" -eq 2 ]
  grep -F "vcluster-head-0.0.0-latest.tgz" "$HELM_CALLS"
  grep -F "vcluster-head-0.0.0-abc1234.tgz" "$HELM_CALLS"
}

@test "adds chartmuseum repo before pushing" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # The repo add line must precede any cm-push line in the call log.
  awk '/repo add chartmuseum/{seen=1} /cm-push/{if(!seen){print "push before add"; exit 1}}' "$HELM_CALLS"
}

# --- Republish latest -------------------------------------------------------

@test "republish-latest is a no-op when pushed version equals repo latest" {
  cat > "$HELM_SEARCH_OUTPUT" <<'JSON'
[{"name":"chartmuseum/my-chart","version":"1.2.3"},
 {"name":"chartmuseum/my-chart","version":"1.2.2"}]
JSON
  REPUBLISH_LATEST=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already the repo's latest"* ]]
  [ "$(helm_call_count "pull chartmuseum/my-chart")" -eq 0 ]
}

@test "republish-latest re-pushes when repo has a newer version" {
  cat > "$HELM_SEARCH_OUTPUT" <<'JSON'
[{"name":"chartmuseum/my-chart","version":"4.7.0"},
 {"name":"chartmuseum/my-chart","version":"1.2.3"}]
JSON
  CHART_VERSIONS_JSON='["1.2.4"]' REPUBLISH_LATEST=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Re-pushing latest version 4.7.0"* ]]
  [ "$(helm_call_count "pull chartmuseum/my-chart --version 4.7.0")" -eq 1 ]
  grep -F "my-chart-4.7.0.tgz" "$HELM_CALLS"
}

@test "republish-latest defaults to false (no search call)" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(helm_call_count "search repo")" -eq 0 ]
}

@test "republish-latest fails loudly when helm pull fails" {
  cat > "$HELM_SEARCH_OUTPUT" <<'JSON'
[{"name":"chartmuseum/my-chart","version":"4.7.0"}]
JSON
  echo "fail" > "$HELM_PULL_FAIL"
  CHART_VERSIONS_JSON='["1.2.4"]' REPUBLISH_LATEST=true run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to pull"* ]]
}

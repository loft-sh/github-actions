#!/usr/bin/env bats

setup() {
  export TEST_DIR="$BATS_TEST_TMPDIR/test"
  mkdir -p "$TEST_DIR/bin"
  export GITHUB_OUTPUT="$TEST_DIR/output"
  export GITHUB_STEP_SUMMARY="$TEST_DIR/summary"
  export GH_CALLS="$TEST_DIR/gh-calls"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  : > "$GH_CALLS"

  cat > "$TEST_DIR/bin/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$GH_CALLS"
printf '%s\n' "${GH_RESPONSE:?GH_RESPONSE is required}"
SCRIPT
  cat > "$TEST_DIR/bin/date" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '2026-08-09'
SCRIPT
  chmod +x "$TEST_DIR/bin/gh" "$TEST_DIR/bin/date"
  export PATH="$TEST_DIR/bin:$PATH"
  export INPUT_REPOSITORY='loft-sh/vcluster-pro'
  export INPUT_SOURCE_PR=''
  export INPUT_LOOKBACK_DAYS='30'
  export INPUT_LABEL_PREFIX='backport-to-'
}

@test "selects only closed merged-search results with backport labels" {
  export GH_RESPONSE='[
    {"number":2285,"state":"MERGED","labels":[{"name":"backport-to-v0.36"}]},
    {"number":2286,"state":"MERGED","labels":[{"name":"bug"}]},
    {"number":2287,"state":"OPEN","labels":[{"name":"backport-to-v0.37"}]}
  ]'

  run "$BATS_TEST_DIRNAME/../run.sh"

  [ "$status" -eq 0 ]
  grep -qx 'source-prs=\[2285\]' "$GITHUB_OUTPUT"
  grep -qx 'selected-count=1' "$GITHUB_OUTPUT"
  grep -q -- 'pr list --repo loft-sh/vcluster-pro --state merged --search merged:>=2026-08-09' "$GH_CALLS"
  grep -q -- '`loft-sh/vcluster-pro#2285`' "$GITHUB_STEP_SUMMARY"
}

@test "explicit source PR bypasses the search and lookback" {
  export INPUT_SOURCE_PR='2285'
  unset GH_RESPONSE

  run "$BATS_TEST_DIRNAME/../run.sh"

  [ "$status" -eq 0 ]
  grep -qx 'source-prs=\[2285\]' "$GITHUB_OUTPUT"
  grep -qx 'selected-count=1' "$GITHUB_OUTPUT"
  [ ! -s "$GH_CALLS" ]
  grep -q 'explicit source PR' "$GITHUB_STEP_SUMMARY"
}

@test "an empty merged window is a successful empty selection" {
  export GH_RESPONSE='[]'

  run "$BATS_TEST_DIRNAME/../run.sh"

  [ "$status" -eq 0 ]
  grep -qx 'source-prs=\[\]' "$GITHUB_OUTPUT"
  grep -qx 'selected-count=0' "$GITHUB_OUTPUT"
  grep -q 'No merged source PRs' "$GITHUB_STEP_SUMMARY"
}

@test "a full GitHub search page fails instead of hiding truncated results" {
  export GH_RESPONSE="$(jq -cn '[range(0; 1000) | {number: ., state: "MERGED", labels: []}]')"

  run "$BATS_TEST_DIRNAME/../run.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"1000-result limit"* ]]
}

@test "invalid explicit source PR fails before search" {
  export INPUT_SOURCE_PR='not-a-number'
  unset GH_RESPONSE

  run "$BATS_TEST_DIRNAME/../run.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *'source-pr must be a positive integer'* ]]
  [ ! -s "$GH_CALLS" ]
}

@test "invalid lookback fails before search" {
  export INPUT_LOOKBACK_DAYS='0'
  unset GH_RESPONSE

  run "$BATS_TEST_DIRNAME/../run.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *'lookback-days must be an integer from 1 to 365'* ]]
  [ ! -s "$GH_CALLS" ]
}

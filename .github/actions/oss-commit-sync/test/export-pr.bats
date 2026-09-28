#!/usr/bin/env bats
# Tests for export-pr.sh (open, update or close the export PR).

setup() {
  ROOT=$(mktemp -d)
  SCRIPT="$BATS_TEST_DIRNAME/../export-pr.sh"
  export GITHUB_OUTPUT="$ROOT/output"
  : > "$GITHUB_OUTPUT"
  export OSS_REPO=loft-sh/vcluster BRANCH=v0.99 PR_BRANCH=sync/v0.99
  export PUSHED=true EXPORTED_COUNT=2
  export GITHUB_REPOSITORY=loft-sh/vcluster-pro GITHUB_RUN_ID=123

  # gh stub. GH_OPEN_PR is the `pr list` JSON; GH_FAIL names a subcommand to
  # fail. Every call is logged, one line of args each.
  export GH_CALLS="$ROOT/calls"
  : > "$GH_CALLS"
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
[ "${GH_FAIL:-}" != "$2" ] || { echo "mock: $2 failed" >&2; exit 1; }
case "$1 $2" in
  "pr list")
    jq_filter=""
    while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && jq_filter="$2"; shift; done
    printf '%s\n' "${GH_OPEN_PR:-[]}" | jq -r "$jq_filter"
    ;;
  "pr create") echo "https://github.com/loft-sh/vcluster/pull/77" ;;
  "pr close") ;;
  *) echo "unsupported: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$ROOT/bin/gh"
  PATH="$ROOT/bin:$PATH"
}

teardown() {
  rm -rf "$ROOT"
}

output_value() {
  grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-
}

@test "no open PR: opens one with a chore(sync) title against the target branch" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value pr-created)" = "true" ]
  [ "$(output_value pr-number)" = "77" ]
  [ "$(output_value pr-url)" = "https://github.com/loft-sh/vcluster/pull/77" ]
  grep -q -- "^pr create --repo loft-sh/vcluster --base v0.99 --head sync/v0.99 --title chore(sync): export staging to v0.99 " "$GH_CALLS"
  grep -q "Rebase and merge" "$GH_CALLS"
  grep -q "loft-sh/vcluster-pro/actions/runs/123" "$GH_CALLS"
}

@test "an open PR: reuses it without opening another" {
  GH_OPEN_PR='[{"number":42,"url":"https://github.com/loft-sh/vcluster/pull/42"}]' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value pr-created)" = "false" ]
  [ "$(output_value pr-number)" = "42" ]
  [ "$(output_value pr-url)" = "https://github.com/loft-sh/vcluster/pull/42" ]
  run grep -c "^pr create" "$GH_CALLS"
  [ "$output" = "0" ]
}

@test "nothing pushed and a PR still open: closes it as stale" {
  PUSHED=false GH_OPEN_PR='[{"number":42,"url":"https://github.com/loft-sh/vcluster/pull/42"}]' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "^pr close 42 --repo loft-sh/vcluster --delete-branch" "$GH_CALLS"
  [ "$(output_value pr-number)" = "" ]
  run grep -c "^pr create" "$GH_CALLS"
  [ "$output" = "0" ]
}

@test "nothing pushed and no PR open: does nothing" {
  PUSHED=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -cE "^pr (create|close)" "$GH_CALLS"
  [ "$output" = "0" ]
}

@test "a failed PR lookup fails the run rather than opening a duplicate" {
  GH_FAIL=list run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to look up an open PR"* ]]
  run grep -c "^pr create" "$GH_CALLS"
  [ "$output" = "0" ]
}

@test "a failed PR create fails the run" {
  GH_FAIL=create run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to open a PR from sync/v0.99 into v0.99"* ]]
  [ "$(output_value pr-created)" = "false" ]
}

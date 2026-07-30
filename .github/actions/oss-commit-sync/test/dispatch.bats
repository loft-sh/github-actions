#!/usr/bin/env bats
# run.sh dispatches each direction with `exec`, which needs the execute bit on
# the target. The other suites invoke the direction scripts as `bash foo.sh`,
# which ignores the mode, so a script committed 100644 passes every one of them
# and then fails in production with a bare "Permission denied" before its body
# runs. health.sh shipped that way. These tests exercise the real entry point.

load helpers

setup() {
  setup_fixture
  RUN="$BATS_TEST_DIRNAME/../run.sh"
  ACTION_DIR="$BATS_TEST_DIRNAME/.."
  export GITHUB_STEP_SUMMARY="$ROOT/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
}

teardown() {
  teardown_fixture
}

@test "every script run.sh execs is committed executable" {
  # Checked against the index, not the working tree: a local chmod does not
  # travel, only the committed mode does.
  cd "$ACTION_DIR"
  for script in run.sh import.sh export.sh health.sh; do
    mode="$(git ls-files -s "$script" | awk '{print $1}')"
    [ "$mode" = "100755" ] || {
      echo "$script is committed $mode, must be 100755 (run.sh execs it)"
      false
    }
  done
}

@test "run.sh dispatches health through exec" {
  # Invoked directly, not via `bash`, so a missing execute bit fails here.
  DIRECTION=health run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(output_value converged)" = "true" ]
}

@test "run.sh dispatches import through exec" {
  external_commit ext.go "one" "feat: alice first" >/dev/null
  DIRECTION=import run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(output_value replayed-count)" = "1" ]
}

@test "run.sh dispatches export through exec" {
  company_commit pkg/new.go "company" "feat: company change" >/dev/null
  DIRECTION=export run "$RUN"
  [ "$status" -eq 0 ]
  [ "$(output_value exported-count)" = "1" ]
}

@test "run.sh rejects an unknown direction" {
  DIRECTION=bogus run "$RUN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown DIRECTION"* ]]
}

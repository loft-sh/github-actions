#!/usr/bin/env bats
# Tests for src/parse-list.sh — the newline-list → repeatable-flag parser the
# s3-stage step uses to build -upload / -presign args.

SCRIPT="$BATS_TEST_DIRNAME/../src/parse-list.sh"

@test "emits one flag per line; values containing '=' are preserved" {
  run bash "$SCRIPT" -upload <<< $'vcluster_image=vcluster.tar\n/tmp/kind-node.tar.gz=kind-node.tar.gz'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "-upload=vcluster_image=vcluster.tar" ]
  [ "${lines[1]}" = "-upload=/tmp/kind-node.tar.gz=kind-node.tar.gz" ]
}

@test "strips trailing CR and surrounding whitespace, skips blank lines" {
  run bash "$SCRIPT" -presign <<< $'  vcluster.tar:get \r\n\r\n\tresults.tar.gz:put\r'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "-presign=vcluster.tar:get" ]
  [ "${lines[1]}" = "-presign=results.tar.gz:put" ]
}

@test "preserves spaces inside a value" {
  run bash "$SCRIPT" -upload <<< '/tmp/my file.tar=obj.tar'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "-upload=/tmp/my file.tar=obj.tar" ]
}

@test "empty input produces no output" {
  run bash "$SCRIPT" -upload <<< ''
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

@test "a whitespace-only list produces no output" {
  run bash "$SCRIPT" -presign <<< $'   \n\t\n'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 0 ]
}

@test "fails when no flag name is given" {
  run bash "$SCRIPT" <<< 'x'
  [ "$status" -ne 0 ]
}

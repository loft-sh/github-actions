#!/usr/bin/env bats
# Tests for find-markers.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/find-markers.sh"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  cd "$REPO"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  export REPORT_FILE="$BATS_TEST_TMPDIR/report.md"
  : > "$GITHUB_OUTPUT"
}

# add_file <path> <content>: write a file and track it
add_file() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
  git add "$1"
}

# Built with printf so no line of this file starts with a marker
conflict=$(printf '%s\n' '<<<<<<< HEAD' 'ARG VERSION="v1"' '=======' 'ARG VERSION="v2"' \
  '>>>>>>> abc1234 (chore: bump version)')

found() { grep -x "found=$1" "$GITHUB_OUTPUT"; }

@test "finds markers in an extensionless file such as a Dockerfile" {
  add_file Dockerfile.release "$conflict"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  found true
  grep -q '^Dockerfile.release:1:<<<<<<< HEAD$' "$REPORT_FILE"
}

@test "finds markers in a go file" {
  add_file pkg/app/main.go "$conflict"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  found true
  grep -q 'pkg/app/main.go:1:' "$REPORT_FILE"
}

@test "finds a closing marker on its own" {
  add_file Makefile '>>>>>>> abc1234 (chore: bump version)'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  found true
}

@test "finds a bare marker with no label" {
  add_file go.mod '<<<<<<<'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  found true
}

@test "clean repository reports no markers and writes no report" {
  add_file Dockerfile 'FROM alpine:3.24'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  found false
  [ ! -e "$REPORT_FILE" ]
}

@test "skips vendor, nested vendor and node_modules" {
  add_file vendor/example.com/lib/lib.go "$conflict"
  add_file staging/mod/vendor/example.com/lib/lib.go "$conflict"
  add_file ui/node_modules/pkg/index.js "$conflict"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  found false
}

@test "ignores a markdown heading underline and markers that do not start a line" {
  add_file README.md 'Title
======='
  add_file docs/guide.txt 'a conflict looks like <<<<<<< HEAD'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  found false
}

@test "ignores binary files" {
  printf '<<<<<<< HEAD\n\000binary\n' > blob.bin
  git add blob.bin
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  found false
}

@test "fails when the scan itself fails instead of reporting no markers" {
  cd "$BATS_TEST_TMPDIR"
  mkdir not-a-repo && cd not-a-repo
  run env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^found=' "$GITHUB_OUTPUT"
}

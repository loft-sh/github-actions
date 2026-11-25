#!/usr/bin/env bats
# Tests for upload.sh.

SCRIPT="$BATS_TEST_DIRNAME/../src/upload.sh"

load aws_mock

setup() {
  setup_aws_mock
  FILES_DIR="$(mktemp -d)"
  printf 'disk' >"$FILES_DIR/disk.tar"
  printf 'installer' >"$FILES_DIR/installer.bin"
  export GITHUB_OUTPUT="$FILES_DIR/github_output"
  : >"$GITHUB_OUTPUT"
  export INPUT_BUCKET=artifacts
  export INPUT_PREFIX=v1.2.3
  export INPUT_FILES="$FILES_DIR/disk.tar
$FILES_DIR/installer.bin"
  unset INPUT_MANIFEST
}

teardown() {
  rm -rf "$FILES_DIR"
  teardown_aws_mock
}

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
uploads() { grep '^s3 cp ' "$AWS_MOCK_CALLS" || true; }

@test "uploads every file with its sha256 and the manifest last" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(cat "$AWS_MOCK_STORE/artifacts/v1.2.3/disk.tar")" = disk ]
  [ "$(cat "$AWS_MOCK_STORE/artifacts/v1.2.3/installer.bin")" = installer ]
  grep -q -- "--metadata sha256=$(sha disk) $FILES_DIR/disk.tar s3://artifacts/v1.2.3/disk.tar" "$AWS_MOCK_CALLS"
  [ "$(uploads | tail -n1 | awk '{print $NF}')" = s3://artifacts/v1.2.3/SHA256SUMS ]
  [ "$(cat "$AWS_MOCK_STORE/artifacts/v1.2.3/SHA256SUMS")" = "$(sha disk)  disk.tar
$(sha installer)  installer.bin" ]
  grep -qx 'manifest-url=s3://artifacts/v1.2.3/SHA256SUMS' "$GITHUB_OUTPUT"
}

@test "the manifest verifies with sha256sum -c" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  cd "$AWS_MOCK_STORE/artifacts/v1.2.3"
  sha256sum -c --quiet SHA256SUMS
}

@test "checks for the manifest under the prefix" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 's3api head-object --bucket artifacts --key v1.2.3/SHA256SUMS' "$AWS_MOCK_CALLS"
}

@test "a released prefix is refused before any upload" {
  export AWS_MOCK_HEAD=exists
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"s3://artifacts/v1.2.3/SHA256SUMS exists: v1.2.3 is already released"* ]]
  [ -z "$(uploads)" ]
}

@test "an access error on the check stops before any upload" {
  export AWS_MOCK_HEAD=denied
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"cannot check s3://artifacts/v1.2.3/SHA256SUMS"*"(403)"* ]]
  [ -z "$(uploads)" ]
}

@test "a failed file upload leaves no manifest" {
  export AWS_MOCK_CP_FAIL=installer.bin
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ ! -e "$AWS_MOCK_STORE/artifacts/v1.2.3/SHA256SUMS" ]
  ! grep -q 'manifest-url=' "$GITHUB_OUTPUT"
}

@test "a custom manifest name is checked and written" {
  export INPUT_MANIFEST=checksums.txt
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 's3api head-object --bucket artifacts --key v1.2.3/checksums.txt' "$AWS_MOCK_CALLS"
  [ -f "$AWS_MOCK_STORE/artifacts/v1.2.3/checksums.txt" ]
}

@test "a nested prefix is accepted" {
  export INPUT_PREFIX=releases/v1.2.3
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$AWS_MOCK_STORE/artifacts/releases/v1.2.3/SHA256SUMS" ]
}

@test "blank lines and surrounding spaces in files are ignored" {
  export INPUT_FILES="
  $FILES_DIR/disk.tar

$FILES_DIR/installer.bin  
"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$AWS_MOCK_STORE/artifacts/v1.2.3/SHA256SUMS")" -eq 2 ]
}

@test "a missing file fails before any aws call" {
  export INPUT_FILES="$FILES_DIR/disk.tar
$FILES_DIR/missing.bin"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"not a file: $FILES_DIR/missing.bin"* ]]
  [ ! -s "$AWS_MOCK_CALLS" ]
}

@test "two files with the same name fail before any aws call" {
  mkdir "$FILES_DIR/other"
  printf 'other' >"$FILES_DIR/other/disk.tar"
  export INPUT_FILES="$FILES_DIR/disk.tar
$FILES_DIR/other/disk.tar"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"would both upload as disk.tar"* ]]
  [ ! -s "$AWS_MOCK_CALLS" ]
}

@test "a file named like the manifest fails" {
  printf 'x' >"$FILES_DIR/SHA256SUMS"
  export INPUT_FILES="$FILES_DIR/SHA256SUMS"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"has the name of the manifest"* ]]
  [ ! -s "$AWS_MOCK_CALLS" ]
}

@test "files with only blank lines fails" {
  export INPUT_FILES="

"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"files lists no file"* ]]
}

@test "a manifest name with a slash fails" {
  export INPUT_MANIFEST=sums/SHA256SUMS
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"manifest must be a file name"* ]]
}

@test "unsafe prefixes fail before any aws call" {
  for p in /v1 v1/ a//b .. ../v1 v1/.. ./v1 a/./b; do
    export INPUT_PREFIX=$p
    run "$SCRIPT"
    [ "$status" -eq 1 ] || { echo "accepted $p"; return 1; }
    [[ $output == *"prefix must be a relative S3 key prefix"* ]]
  done
  [ ! -s "$AWS_MOCK_CALLS" ]
}

@test "a dotted name that is not . or .. is a valid prefix" {
  export INPUT_PREFIX=v1.2.3-rc.1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

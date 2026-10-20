#!/usr/bin/env bats
# Tests for go-licenses/configure-git.sh
#
# Points git's global config at a temp file so the script's
# `git config --global` writes land there, then asks git itself which
# credentials it would hand out.

SCRIPT="$BATS_TEST_DIRNAME/../configure-git.sh"

setup() {
  TEST_DIR=$(mktemp -d)
  export GIT_CONFIG_GLOBAL="$TEST_DIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  # Make an unanswered credential request fail instead of prompting.
  export GIT_TERMINAL_PROMPT=0
  unset GIT_ASKPASS SSH_ASKPASS
  export GH_ACCESS_TOKEN="dummy-token-123"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "fails without GH_ACCESS_TOKEN and writes no config" {
  unset GH_ACCESS_TOKEN
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GH_ACCESS_TOKEN is required"* ]]
  [ ! -s "$GIT_CONFIG_GLOBAL" ]
}

@test "writes a github.com credential helper and no insteadOf rewrite" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  helper=$(git config --global --get credential.https://github.com.helper)
  [[ "$helper" == *"password=dummy-token-123"* ]]
  run git config --global --get-regexp 'insteadof'
  [ "$status" -eq 1 ]
}

@test "git hands the token to github.com" {
  bash "$SCRIPT"
  run git credential fill <<< $'protocol=https\nhost=github.com\npath=loft-sh/private-module.git\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"username=x-access-token"* ]]
  [[ "$output" == *"password=dummy-token-123"* ]]
}

@test "git does not hand the token to other hosts" {
  bash "$SCRIPT"
  run git credential fill <<< $'protocol=https\nhost=gitlab.com\n'
  [ "$status" -ne 0 ]
  [[ "$output" != *"dummy-token-123"* ]]
}

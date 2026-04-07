#!/usr/bin/env bats
# Tests for detect-branch.sh
#
# Each test creates an isolated git repo with a controlled branch/tag topology,
# then runs detect-branch.sh and asserts the output.

SCRIPT="$BATS_TEST_DIRNAME/../detect-branch.sh"

setup() {
  TEST_REPO=$(mktemp -d)
  git -C "$TEST_REPO" init --bare -b main remote.git >/dev/null 2>&1
  git clone "$TEST_REPO/remote.git" "$TEST_REPO/local" >/dev/null 2>&1
  cd "$TEST_REPO/local"
  git config user.email "test@test.com"
  git config user.name "Test"
}

teardown() {
  rm -rf "$TEST_REPO"
}

make_commit() {
  local msg="${1:-commit}"
  echo "$msg" >> file.txt
  git add file.txt
  git commit -m "$msg" >/dev/null 2>&1
  git rev-parse HEAD
}

push_all() {
  git push origin --all >/dev/null 2>&1
  git push origin --tags >/dev/null 2>&1
}

# Helper: run the script capturing only stdout (stderr goes to debug log)
run_script() {
  run bash -c "RELEASE_VERSION='$1' ${2:+DEFAULT_BRANCH='$2'} '$SCRIPT' 2>/dev/null"
}

# --- Tests ---

@test "tag on main returns main" {
  make_commit "initial"
  make_commit "second"
  git tag v1.0.0
  push_all

  run_script v1.0.0
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "tag on release branch returns that branch" {
  make_commit "initial"
  push_all

  git checkout -b release/v1.1
  make_commit "release work"
  git tag v1.1.0
  push_all

  git checkout main
  make_commit "main continues"
  push_all

  run_script v1.1.0
  [ "$status" -eq 0 ]
  [ "$output" = "release/v1.1" ]
}

@test "tag on branch with extra commits still picks closest branch" {
  make_commit "initial"
  push_all

  git checkout -b release/v2.0
  make_commit "rel commit 1"
  git tag v2.0.0
  make_commit "rel commit 2"
  push_all

  git checkout main
  make_commit "main work"
  push_all

  run_script v2.0.0
  [ "$status" -eq 0 ]
  [ "$output" = "release/v2.0" ]
}

@test "picks branch with smallest distance when tag is on multiple branches" {
  make_commit "initial"
  push_all

  # Branch A: tag + 3 more commits after tag
  git checkout -b branch-a
  make_commit "a1"
  git tag v3.0.0
  make_commit "a2"
  make_commit "a3"
  make_commit "a4"
  push_all

  # Branch B: fork from tag, only 1 extra commit
  git checkout v3.0.0
  git checkout -b branch-b
  make_commit "b1"
  push_all

  git checkout main
  make_commit "main work"
  push_all

  run_script v3.0.0
  [ "$status" -eq 0 ]
  # branch-a distance=3, branch-b distance=1 → branch-b wins
  [ "$output" = "branch-b" ]
}

@test "defaults to main when no branches contain the tag" {
  make_commit "initial"
  push_all

  # Orphan branch — push only the tag, not the branch ref
  git checkout --orphan orphan-branch
  git rm -rf . >/dev/null 2>&1
  echo "orphan" > file.txt
  git add file.txt
  git commit -m "orphan" >/dev/null 2>&1
  git tag v0.0.1
  git push origin v0.0.1 >/dev/null 2>&1

  run_script v0.0.1
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "respects DEFAULT_BRANCH override" {
  make_commit "initial"
  push_all

  git checkout --orphan orphan-branch
  git rm -rf . >/dev/null 2>&1
  echo "orphan" > file.txt
  git add file.txt
  git commit -m "orphan" >/dev/null 2>&1
  git tag v0.0.2
  git push origin v0.0.2 >/dev/null 2>&1

  run_script v0.0.2 develop
  [ "$status" -eq 0 ]
  [ "$output" = "develop" ]
}

@test "fails when RELEASE_VERSION is not set" {
  make_commit "initial"
  push_all

  run bash -c "'$SCRIPT' 2>/dev/null"
  [ "$status" -ne 0 ]
}

@test "origin/HEAD symref is ignored" {
  make_commit "initial"
  push_all

  git checkout -b release/v5.0
  make_commit "release work"
  git tag v5.0.0
  push_all

  # Create origin/HEAD pointing at main — simulates what GitHub remotes do
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  git checkout main
  make_commit "main continues"
  push_all

  run_script v5.0.0
  [ "$status" -eq 0 ]
  [ "$output" = "release/v5.0" ]
}

@test "fails when tag does not exist" {
  make_commit "initial"
  push_all

  run_script v99.99.99
  [ "$status" -ne 0 ]
}

@test "skips branch whose merge-base is not ancestor of tag" {
  # Topology:
  #   main:        A --- B --- D --- E
  #   release/v6:       \--- C (tag v6.0.0)
  #   late-branch:             \--- merge(C) --- F
  #
  # late-branch contains the tag commit via merge, but merge-base(main, late)
  # is D which is NOT an ancestor of C. The is-ancestor guard should skip it.

  make_commit "A"
  make_commit "B"
  push_all

  git checkout -b release/v6.0
  make_commit "C"
  git tag v6.0.0
  push_all

  git checkout main
  make_commit "D"
  make_commit "E"
  push_all

  git checkout -b late-branch
  git merge v6.0.0 -m "merge release tag" -X ours >/dev/null
  make_commit "F"
  push_all

  run_script v6.0.0
  [ "$status" -eq 0 ]
  # release/v6.0 should win; late-branch should be skipped by the is-ancestor guard
  [ "$output" = "release/v6.0" ]
}

@test "tag at branch point shared by main and release picks main (distance 0)" {
  make_commit "initial"
  make_commit "second"
  git tag v4.0.0
  push_all

  git checkout -b release/v4.0
  make_commit "release work"
  push_all

  run_script v4.0.0
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

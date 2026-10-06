#!/usr/bin/env bats
# Tests for detect-branch.sh
#
# Each test creates an isolated git repo with a controlled branch/tag topology,
# then runs detect-branch.sh and asserts the output.

SCRIPT="$BATS_TEST_DIRNAME/../detect-branch.sh"

setup() {
  TEST_REPO=$(mktemp -d)
  # The no-checkout tests run in TEST_REPO and must not find a repo above it.
  export GIT_CEILING_DIRECTORIES="$(dirname "$TEST_REPO")"
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

@test "missing tag warns and falls back to the default branch" {
  # The banner is advisory, so a branch it cannot name must not block it.
  make_commit "initial"
  push_all

  run bash -c "RELEASE_VERSION=v99.99.99 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::cannot read tag v99.99.99"* ]]
  [ "${lines[-1]}" = "main" ]
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

# --- main moving on, and the caller's branch ---

run_with_base() {
  run bash -c "RELEASE_VERSION='$1' BASE_BRANCH='$2' '$SCRIPT' 2>/dev/null"
}

@test "prerelease on main still returns main after main moves on and a branch forks at the tag" {
  # The feature branch's tip is closer to the tag than main's, so a
  # closest-tip guess would name it.
  make_commit "initial"
  git tag v4.13.0-alpha.20
  push_all

  git checkout -b feature/forked-at-tag
  make_commit "feature work"
  push_all

  git checkout main
  make_commit "main continues"
  make_commit "main continues more"
  push_all

  run_script v4.13.0-alpha.20
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "alpha prefers main over a release line branched after it" {
  # Alphas come only from main, so a line that also holds the tag branched later.
  make_commit "initial"
  git tag v4.13.0-alpha.3
  make_commit "main continues"
  push_all

  git checkout -b release-4.13
  make_commit "release work"
  push_all

  run_script v4.13.0-alpha.3
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "rc at a release line's branch point prefers the line over main" {
  # A coin flip in real history, slightly more often the line.
  make_commit "initial"
  git tag v4.13.0-rc.0
  git checkout -b release-4.13
  push_all
  git checkout main
  make_commit "main continues"
  push_all

  run_script v4.13.0-rc.0
  [ "$status" -eq 0 ]
  [ "$output" = "release-4.13" ]
}

@test "rc cut on main before its line exists returns main" {
  make_commit "initial"
  git tag v4.13.0-rc.0
  make_commit "main continues"
  push_all

  run_script v4.13.0-rc.0
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "stable prefers its release-X.Y line over main" {
  # A tag at the branch point is on both; stables are only cut from the line.
  make_commit "initial"
  git tag v4.12.0
  git checkout -b release-4.12
  make_commit "backport"
  push_all
  git checkout main
  make_commit "main continues"
  push_all

  run_script v4.12.0
  [ "$status" -eq 0 ]
  [ "$output" = "release-4.12" ]
}

@test "stable finds a vX.Y release line" {
  make_commit "initial"
  push_all
  git checkout -b v0.37
  make_commit "release work"
  git tag v0.37.1
  git checkout -b feature/forked-at-tag
  make_commit "feature work"
  push_all

  run_script v0.37.1
  [ "$status" -eq 0 ]
  [ "$output" = "v0.37" ]
}

@test "given base branch is used when the tag is on it" {
  make_commit "initial"
  push_all
  git checkout -b feature/next-work
  make_commit "feature work"
  git tag v4.13.0-next.1
  push_all

  run_with_base v4.13.0-next.1 feature/next-work
  [ "$status" -eq 0 ]
  [ "$output" = "feature/next-work" ]
}

@test "given base branch the tag is not on is ignored" {
  make_commit "initial"
  git tag v4.13.0-alpha.1
  push_all
  git checkout -b release-4.13
  make_commit "release work"
  git checkout --orphan unrelated
  make_commit "unrelated"
  push_all

  run bash -c "RELEASE_VERSION=v4.13.0-alpha.1 BASE_BRANCH=unrelated '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::v4.13.0-alpha.1 is not on unrelated"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "given base branch is trusted when the branch is gone from the remote" {
  # A -next feature branch can be deleted while its build runs.
  make_commit "initial"
  git tag v4.13.0-next.2
  push_all

  run_with_base v4.13.0-next.2 feature/deleted
  [ "$status" -eq 0 ]
  [ "$output" = "feature/deleted" ]
}

@test "given base branch is trusted when the tag is not available" {
  make_commit "initial"
  push_all

  # Not main, which is also the fallback for an unreadable tag.
  run_with_base v9.9.9 release-9.9
  [ "$status" -eq 0 ]
  [ "$output" = "release-9.9" ]
}

@test "given base branch that names a tag is ignored" {
  make_commit "initial"
  git tag v4.13.0-alpha.3
  make_commit "second"
  git tag v4.13.0-alpha.4
  git checkout -b feature/forked-at-tag
  make_commit "feature work"
  push_all

  run bash -c "RELEASE_VERSION=v4.13.0-alpha.4 BASE_BRANCH=v4.13.0-alpha.3 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::base_branch v4.13.0-alpha.3 names a tag"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "given base branch that names a tag is not used even when no branch holds the tag" {
  make_commit "initial"
  git tag v4.13.0-alpha.3
  git checkout --orphan detached
  make_commit "elsewhere"
  git tag v4.13.0-next.9
  git checkout main
  push_all
  git push origin --delete detached >/dev/null 2>&1

  run_with_base v4.13.0-next.9 v4.13.0-alpha.3
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "base branch equal to the release version is ignored without a checkout" {
  cd "$TEST_REPO"
  run bash -c "RELEASE_VERSION=v4.11.3 BASE_BRANCH=v4.11.3 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::base_branch v4.11.3 is the release tag"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "HEAD and ref paths are not taken as branch names" {
  make_commit "initial"
  git tag v4.13.0-alpha.5
  git checkout -b feature/forked-at-tag
  make_commit "feature work"
  push_all
  git remote set-head origin main >/dev/null 2>&1

  for b in HEAD refs/heads/main refs/tags/v4.13.0-alpha.5; do
    run bash -c "RELEASE_VERSION=v4.13.0-alpha.5 BASE_BRANCH=$b '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::base_branch is not a plain branch name"* ]]
    [ "${lines[-1]}" = "main" ]
  done
}

@test "given base branch is used when it was rewritten and no branch holds the tag" {
  make_commit "initial"
  push_all
  git checkout -b feature/rebased
  make_commit "feature work"
  git tag v4.13.0-next.4
  push_all
  git reset --hard main >/dev/null 2>&1
  make_commit "rewritten"
  git push -f origin feature/rebased >/dev/null 2>&1

  run_with_base v4.13.0-next.4 feature/rebased
  [ "$status" -eq 0 ]
  [ "$output" = "feature/rebased" ]
}

@test "surrounding whitespace in the version and branch is ignored" {
  make_commit "initial"
  push_all
  git checkout -b release-4.11
  make_commit "release work"
  git tag v4.11.3
  push_all

  run bash -c "RELEASE_VERSION=\$'v4.11.3\n' BASE_BRANCH=' release-4.11 ' '$SCRIPT' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "release-4.11" ]
}

@test "rc cut on main stays main when the line is branched later from a newer main" {
  make_commit "initial"
  git tag v4.13.0-rc.0
  make_commit "main continues"
  git checkout -b release-4.13
  make_commit "release work"
  push_all

  run_script v4.13.0-rc.0
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "rc on its line after line commits returns the line" {
  make_commit "initial"
  git checkout -b release-4.13
  make_commit "release work"
  git tag v4.13.0-rc.1
  git checkout main
  make_commit "main continues"
  push_all

  run_script v4.13.0-rc.1
  [ "$status" -eq 0 ]
  [ "$output" = "release-4.13" ]
}

@test "unsupported prerelease suffix is not treated as an rc" {
  make_commit "initial"
  git tag v4.13.0-devpod-rc.1
  git checkout -b release-4.13
  push_all
  git checkout main
  make_commit "main continues"
  push_all

  run_script v4.13.0-devpod-rc.1
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "given base branch the dispatchers accept is used" {
  make_commit "initial"
  push_all
  git checkout -b _wip/feature
  make_commit "feature work"
  git tag v4.13.0-next.3
  push_all

  run_with_base v4.13.0-next.3 _wip/feature
  [ "$status" -eq 0 ]
  [ "$output" = "_wip/feature" ]
}

@test "unreadable tag falls back to main with git's reason instead of failing" {
  cd "$TEST_REPO"
  run bash -c "RELEASE_VERSION=v1.2.3 BASE_BRANCH='feat/\"x\"' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::cannot read tag v1.2.3"*"not a git repository"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "a newline in the version cannot start a second workflow command" {
  make_commit "initial"
  push_all

  run bash -c "RELEASE_VERSION=\$'v1.2.3\n::error::forged' '$SCRIPT'"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "${lines[@]}" | grep -q '^::error::forged'
}

@test "a tag that is not a version still finds main" {
  make_commit "initial"
  git tag nightly
  push_all

  run_script nightly
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "given base branch that is not a plain branch name is ignored" {
  # It would end the quoted string in the Slack payload's YAML.
  make_commit "initial"
  git tag v4.13.0-alpha.2
  push_all

  run bash -c "RELEASE_VERSION=v4.13.0-alpha.2 BASE_BRANCH='feat/\"x\"' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::base_branch is not a plain branch name"* ]]
  [[ "$output" != *'feat/"x"'* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "-next prefers its feature branch over main when both hold the tag" {
  make_commit "initial"
  git checkout -b feature/fresh
  git tag v4.13.0-next.5
  make_commit "feature work"
  make_commit "more feature work"
  git checkout main
  push_all

  run_script v4.13.0-next.5
  [ "$status" -eq 0 ]
  [ "$output" = "feature/fresh" ]
}

@test "-next falls back to main when no feature branch holds the tag" {
  make_commit "initial"
  git tag v4.13.0-next.internal.1
  push_all

  run_script v4.13.0-next.internal.1
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "given base branch that names a commit or a remote-tracking ref is ignored" {
  make_commit "initial"
  git tag v4.13.0-alpha.6
  git checkout -b feature/forked-at-tag
  make_commit "feature work"
  push_all

  run bash -c "RELEASE_VERSION=v4.13.0-alpha.6 BASE_BRANCH=$(git rev-parse --short main) '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::base_branch $(git rev-parse --short main) names a commit"* ]]
  [ "${lines[-1]}" = "main" ]
  run bash -c "RELEASE_VERSION=v4.13.0-alpha.6 BASE_BRANCH=origin/main '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::base_branch origin/main is a ref path"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "origin/HEAD is not taken as a branch named origin" {
  # With origin/main gone the closest-tip loop matches nothing and the first
  # listed branch wins, and "origin" sorts first.
  make_commit "initial"
  git checkout -b feature/only
  make_commit "feature work"
  git tag nightly
  push_all
  git update-ref -d refs/remotes/origin/main
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feature/only

  run_script nightly
  [ "$status" -eq 0 ]
  [ "$output" = "feature/only" ]
}

@test "a long branch list does not break the first-branch fallback" {
  make_commit "initial"
  git tag nightly
  push_all
  git update-ref -d refs/remotes/origin/main
  for i in $(seq 3000); do
    printf 'create refs/remotes/origin/feature/a-fairly-long-branch-name-%04d HEAD\n' "$i"
  done | git update-ref --stdin

  run_script nightly
  [ "$status" -eq 0 ]
  [ "$output" = "feature/a-fairly-long-branch-name-0001" ]
}

@test "a version with no patch gets no release line" {
  make_commit "initial"
  git tag v1
  git checkout -b v1.1
  make_commit "line work"
  git checkout main
  make_commit "main continues"
  push_all

  run_script v1
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "-next whose feature branches all fail the fork check falls back to main" {
  # Neither branch is the real source, and main holds the tag.
  make_commit "initial"
  git tag v0.38.0-next.1
  make_commit "main continues"
  git checkout -b dependabot/go_modules/x
  make_commit "bump"
  git checkout main
  push_all

  run_script v0.38.0-next.1
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "-next keeps a rewritten feature branch over main" {
  # The tag is left on main only, which never cuts a -next.
  make_commit "initial"
  make_commit "feature work"
  git branch feature/x
  git tag v4.13.0-next.7
  make_commit "main continues"
  push_all
  git checkout feature/x
  git reset --hard HEAD~1 >/dev/null 2>&1
  make_commit "rewritten"
  git push -f origin feature/x >/dev/null 2>&1

  run bash -c "RELEASE_VERSION=v4.13.0-next.7 BASE_BRANCH=feature/x '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rebased since the cut"* ]]
  [ "${lines[-1]}" = "feature/x" ]
}

@test "-next keeps a rebased feature branch even when another feature branch holds the tag" {
  make_commit "initial"
  make_commit "feature work"
  git branch feature/x
  git tag v4.13.0-next.8
  make_commit "main continues"
  git branch dependabot/go/x
  push_all
  git checkout feature/x
  git reset --hard HEAD~1 >/dev/null 2>&1
  make_commit "rebased"
  git push -f origin feature/x >/dev/null 2>&1

  run_with_base v4.13.0-next.8 feature/x
  [ "$status" -eq 0 ]
  [ "$output" = "feature/x" ]
}

@test "-next drops a given main or line the tag is not on" {
  make_commit "initial"
  push_all
  git checkout -b release-4.13
  make_commit "line work"
  git tag v4.13.0-next.9
  push_all

  run bash -c "RELEASE_VERSION=v4.13.0-next.9 BASE_BRANCH=main '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::v4.13.0-next.9 is not on main"* ]]
  [ "${lines[-1]}" = "release-4.13" ]
}

@test "a given branch the tag is not on is dropped even when no branch holds the tag" {
  make_commit "initial"
  push_all
  git checkout -b release-4.12
  make_commit "line work"
  git push origin release-4.12 >/dev/null 2>&1
  git checkout --orphan detached
  make_commit "elsewhere"
  git tag v4.12.0-alpha.1
  git push origin v4.12.0-alpha.1 >/dev/null 2>&1

  run_with_base v4.12.0-alpha.1 release-4.12
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "SHAs and origin/ names are ignored without a checkout" {
  cd "$TEST_REPO"
  # Both SHA-1 and SHA-256 lengths.
  for b in 0123abcd "$(printf '%064d' 0)"; do
    run bash -c "RELEASE_VERSION=v4.12.0 BASE_BRANCH=$b '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::base_branch $b names a commit"* ]]
    [ "${lines[-1]}" = "main" ]
  done
  run bash -c "RELEASE_VERSION=v4.12.0 BASE_BRANCH=origin/main '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::base_branch origin/main is a ref path"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "stable keeps a given line rebased off the tag" {
  make_commit "initial"
  push_all
  git checkout -b v0.36
  make_commit "line work"
  git tag v0.36.1
  push_all
  git reset --hard HEAD~1 >/dev/null 2>&1
  make_commit "rebased"
  git push -f origin v0.36 >/dev/null 2>&1

  run bash -c "RELEASE_VERSION=v0.36.1 BASE_BRANCH=v0.36 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rebased since the cut"* ]]
  [ "${lines[-1]}" = "v0.36" ]
}

@test "short ref paths are not taken as branch names" {
  make_commit "initial"
  git tag v4.13.0-alpha.7
  git checkout -b feature/forked-at-tag
  make_commit "feature work"
  push_all

  for b in heads/main tags/v4.13.0-alpha.7 remotes/origin/main; do
    run bash -c "RELEASE_VERSION=v4.13.0-alpha.7 BASE_BRANCH=$b '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::base_branch $b is a ref path"* ]]
    [ "${lines[-1]}" = "main" ]
  done
}

@test "a hex-named branch that holds the tag is used" {
  make_commit "initial"
  push_all
  git checkout -b 20251005
  make_commit "feature work"
  git tag v4.13.0-next.10
  push_all

  run_with_base v4.13.0-next.10 20251005
  [ "$status" -eq 0 ]
  [ "$output" = "20251005" ]
}

@test "the closest-tip pick skips a name the payload cannot carry" {
  make_commit "initial"
  push_all
  git checkout -b hotfix/real
  make_commit "fix"
  git tag v4.13.0-rc.3
  make_commit "more"
  make_commit "more still"
  git checkout -b wip+x v4.13.0-rc.3
  make_commit "wip"
  push_all

  run_script v4.13.0-rc.3
  [ "$status" -eq 0 ]
  [ "$output" = "hotfix/real" ]
}

@test "a tag named like a remote branch does not hide the branch" {
  make_commit "initial"
  push_all
  git tag origin/release-4.12
  git checkout -b release-4.12
  make_commit "line work"
  git tag v4.12.0
  git checkout main
  make_commit "main continues"
  push_all
  git checkout -b aaa v4.12.0
  push_all

  run bash -c "RELEASE_VERSION=v4.12.0 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"release-4.12 (contains the tag)"* ]]
  [ "${lines[-1]}" = "release-4.12" ]
}

@test "a tag given as the branch is ignored when the release tag is not in the checkout" {
  make_commit "initial"
  git tag v4.12.0-alpha.1
  push_all

  run bash -c "RELEASE_VERSION=v4.12.0-alpha.9 BASE_BRANCH=v4.12.0-alpha.1 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::base_branch v4.12.0-alpha.1 names a tag"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "a hex-named branch deleted after the cut is kept when no commit has that name" {
  make_commit "initial"
  push_all
  git checkout -b 20251005
  make_commit "feature work"
  git tag v4.13.0-next.11
  push_all
  git checkout main
  git push origin --delete 20251005 >/dev/null 2>&1
  git fetch --prune >/dev/null 2>&1

  run bash -c "RELEASE_VERSION=v4.13.0-next.11 BASE_BRANCH=20251005 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"20251005 (given, branch not on remote to check)"* ]]
  [ "${lines[-1]}" = "20251005" ]
}

@test "pseudo-refs and origin are not taken as branch names" {
  make_commit "initial"
  git tag v4.13.0-alpha.8
  git checkout -b feature/forked-at-tag
  make_commit "feature work"
  push_all

  for b in FETCH_HEAD ORIG_HEAD MERGE_HEAD origin; do
    run bash -c "RELEASE_VERSION=v4.13.0-alpha.8 BASE_BRANCH=$b '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::base_branch is not a plain branch name"* ]]
    [ "${lines[-1]}" = "main" ]
  done
}

@test "a given branch git cannot check is kept, with git's reason" {
  # Commits missing from the checkout, as in a shallow or partial clone.
  make_commit "initial"
  git tag v4.13.0-alpha.9
  local missing
  missing=$(make_commit "between")
  make_commit "tip"
  push_all
  git checkout -b feature/elsewhere v4.13.0-alpha.9 >/dev/null 2>&1
  make_commit "feature work"
  push_all
  rm ".git/objects/${missing:0:2}/${missing:2}"

  run bash -c "RELEASE_VERSION=v4.13.0-alpha.9 BASE_BRANCH=main '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::cannot check whether v4.13.0-alpha.9 is on main. git said: "*"$missing"* ]]
  [[ "$output" == *"main (given, git could not check it)"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "-next that main merged skips the branches forked from main since" {
  make_commit "initial"
  git checkout -b feature/x
  make_commit "feature work"
  git tag v4.13.0-next.12
  git checkout main
  git merge --no-ff -m merge feature/x >/dev/null 2>&1
  git branch feature/later
  git checkout -b feature/stacked v4.13.0-next.12 >/dev/null 2>&1
  make_commit "stacked work"
  git checkout main
  push_all
  git push origin --delete feature/x >/dev/null 2>&1
  git fetch --prune >/dev/null 2>&1

  run bash -c "RELEASE_VERSION=v4.13.0-next.12 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Remote branches containing this commit: feature/stacked"* ]]
  [[ "$output" != *"feature/later"* ]]
  [ "${lines[-1]}" = "feature/stacked" ]
}

@test "-next that main merged falls back to main when no branch forked at the tag" {
  make_commit "initial"
  git checkout -b feature/x
  make_commit "feature work"
  git tag v4.13.0-next.13
  git checkout main
  git merge --no-ff -m merge feature/x >/dev/null 2>&1
  git branch feature/later
  push_all
  git push origin --delete feature/x >/dev/null 2>&1
  git fetch --prune >/dev/null 2>&1

  run bash -c "RELEASE_VERSION=v4.13.0-next.13 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main (fallback, main holds the tag)"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "a version git would read as an option, a revision or a branch is not taken as the tag" {
  make_commit "initial"
  make_commit "second"
  git tag v1.0.0
  push_all

  for v in --all -n v1.0.0^ v1.0.0~1 main; do
    run bash -c "RELEASE_VERSION='$v' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"main (fallback, tag not readable)"* ]]
  done
}

@test "an annotated tag is read" {
  make_commit "initial"
  git tag -a v1.0.0 -m "release"
  push_all

  run bash -c "RELEASE_VERSION=v1.0.0 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main (contains the tag)"* ]]
}

# A depth-1 clone holding main's tip and the tag commit, with the history
# between them cut.
shallow_clone() {
  git clone -q --depth 1 "file://$TEST_REPO/remote.git" "$TEST_REPO/shallow" >/dev/null 2>&1
  git -C "$TEST_REPO/shallow" fetch -q --depth 1 origin tag "$1" >/dev/null 2>&1
  cd "$TEST_REPO/shallow"
}

@test "a given branch a shallow checkout cannot check is kept" {
  make_commit "initial"
  git tag v1.0.0
  make_commit "second"
  make_commit "third"
  push_all
  shallow_clone v1.0.0
  [ "$(git rev-parse --is-shallow-repository)" = true ]

  run bash -c "RELEASE_VERSION=v1.0.0 BASE_BRANCH=main '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::cannot check whether v1.0.0 is on main. The checkout is shallow"* ]]
  [[ "$output" == *"main (given, git could not check it)"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "a shallow checkout warns when it cannot tell whether main holds the tag" {
  make_commit "initial"
  git tag v1.0.0
  make_commit "second"
  make_commit "third"
  push_all
  shallow_clone v1.0.0
  [ "$(git rev-parse --is-shallow-repository)" = true ]

  run bash -c "RELEASE_VERSION=v1.0.0 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::cannot check whether v1.0.0 is on main. The checkout is shallow"* ]]
  [[ "$output" != *"(contains the tag)"* ]]
}

@test "a shallow checkout that reaches the tag still checks the given branch" {
  make_commit "initial"
  make_commit "second"
  git tag v1.0.0
  push_all
  shallow_clone v1.0.0
  [ "$(git rev-parse --is-shallow-repository)" = true ]

  run bash -c "RELEASE_VERSION=v1.0.0 BASE_BRANCH=main '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main (given)"* ]]
  [[ "$output" != *"::warning::"* ]]
}

@test "a describe-shaped version is not taken as a tag" {
  make_commit "initial"
  git tag v1.0.0
  make_commit "second"
  push_all

  run bash -c "RELEASE_VERSION=$(git describe --tags) '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main (fallback, tag not readable)"* ]]
}

@test "a shallow checkout still drops a given branch whose tip is older than the tag" {
  make_commit "initial"
  make_commit "old 1"
  make_commit "old 2"
  make_commit "old 3"
  make_commit "second"
  git checkout -b feature/foo
  make_commit "feature work"
  git tag v1.1.0-next.1
  make_commit "more feature work"
  git checkout main
  push_all
  git clone -q --depth 3 --no-single-branch "file://$TEST_REPO/remote.git" "$TEST_REPO/shallow" >/dev/null 2>&1
  cd "$TEST_REPO/shallow"
  [ "$(git rev-parse --is-shallow-repository)" = true ]

  run bash -c "RELEASE_VERSION=v1.1.0-next.1 BASE_BRANCH=main '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::v1.1.0-next.1 is not on main"* ]]
  [[ "$output" != *"cannot check"* ]]
  [ "${lines[-1]}" = "feature/foo" ]
}

@test "a shallow checkout still drops a given branch that forked from the tag's history within reach" {
  make_commit "initial"
  make_commit "old 1"
  make_commit "old 2"
  make_commit "old 3"
  make_commit "fork point"
  git checkout -b release-1.0
  make_commit "line work"
  git checkout main
  make_commit "main work"
  git tag v1.1.0-alpha.1
  push_all
  git clone -q --depth 3 --no-single-branch "file://$TEST_REPO/remote.git" "$TEST_REPO/shallow" >/dev/null 2>&1
  cd "$TEST_REPO/shallow"
  [ "$(git rev-parse --is-shallow-repository)" = true ]

  run bash -c "RELEASE_VERSION=v1.1.0-alpha.1 BASE_BRANCH=release-1.0 '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::v1.1.0-alpha.1 is not on release-1.0"* ]]
  [[ "$output" != *"cannot check"* ]]
  [ "${lines[-1]}" = "main" ]
}

@test "an all-caps branch name ending in HEAD is kept" {
  make_commit "initial"
  push_all
  git checkout -b AHEAD
  make_commit "feature work"
  git tag v4.13.0-next.14
  push_all

  run_with_base v4.13.0-next.14 AHEAD
  [ "$status" -eq 0 ]
  [ "$output" = "AHEAD" ]
}

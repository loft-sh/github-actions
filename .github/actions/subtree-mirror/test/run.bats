#!/usr/bin/env bats
# Tests for run.sh
#
# Uses real temporary git repos (a "pro" monorepo with a subtree prefix and a
# bare "oss" remote) so the subtree split + marker-guard logic is exercised
# end to end. Pushes go to a local bare repo, not the network.

setup() {
  ROOT=$(mktemp -d)
  export ROOT
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
  export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always

  SCRIPT="$BATS_TEST_DIRNAME/../run.sh"
  PFX="staging/github.com/loft-sh/vcluster"

  # Bare "OSS" remote seeded with an initial commit on main.
  OSS_REMOTE="$ROOT/oss.git"
  export OSS_REMOTE
  git init -q --bare "$OSS_REMOTE"
  git init -q "$ROOT/ossseed"
  (
    cd "$ROOT/ossseed"
    git checkout -q -b main
    echo "v1" > app.go
    git add . && git commit -qm "oss: initial"
    git push -q "$OSS_REMOTE" main
  )

  # "Pro" monorepo: same content under the subtree prefix, plus a pro-only file.
  export PRO="$ROOT/pro"
  git init -q "$PRO"
  cd "$PRO"
  git checkout -q -b main
  mkdir -p "$PFX"
  echo "v1" > "$PFX/app.go"
  echo "pro-only" > pro.txt
  git add . && git commit -qm "pro: seed subtree"

  export SUBTREE_PREFIX="$PFX"
  export BRANCH=main
  export MARKER_REF=refs/sync/mirror-head
  export GITHUB_OUTPUT="$ROOT/output"
  : > "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$ROOT"
}

# Read the last-written value of an Actions output key.
output_value() {
  grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-
}

oss_branch_sha() {
  git -C "$OSS_REMOTE" rev-parse "refs/heads/$1"
}

oss_file() {
  # $1 = branch, $2 = path
  git -C "$OSS_REMOTE" show "$1:$2"
}

# Add an external commit straight onto OSS main, like a contributor PR merge.
add_external_commit() {
  git clone -q "$OSS_REMOTE" "$ROOT/ext"
  (
    cd "$ROOT/ext"
    git checkout -q main
    echo "external-feature" > ext.go
    git add . && git commit -qm "oss: external contributor PR"
    git push -q origin main
  )
}

# --- fast-forward (release line) mode -------------------------------------

@test "force=false creates a missing branch" {
  FORCE=false BRANCH=v0.36 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  run oss_branch_sha v0.36
  [ "$status" -eq 0 ]
}

@test "force=false fails on a non-fast-forward update" {
  # Seed the OSS release branch with unrelated history.
  git -C "$ROOT/ossseed" checkout -q -b v0.36
  git -C "$ROOT/ossseed" commit -q --allow-empty -m "oss: divergent release history"
  git -C "$ROOT/ossseed" push -q "$OSS_REMOTE" v0.36

  FORCE=false BRANCH=v0.36 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

# --- force (mirror) mode --------------------------------------------------

@test "force first sync pushes and creates the marker" {
  FORCE=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  [ "$(output_value diverged)" = "false" ]
  # marker now equals main
  [ "$(oss_branch_sha main)" = "$(git -C "$OSS_REMOTE" rev-parse "$MARKER_REF")" ]
}

@test "force pro-only change syncs when marker matches remote" {
  FORCE=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  echo "v2" > "$PFX/app.go"
  git commit -qam "pro: bump to v2"
  FORCE=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  [ "$(oss_file main app.go)" = "v2" ]
}

@test "force fails closed when OSS has an external commit" {
  FORCE=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  add_external_commit
  before=$(oss_branch_sha main)

  echo "v2" > "$PFX/app.go"
  git commit -qam "pro: bump to v2"
  FORCE=true run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  [ "$(output_value diverged)" = "true" ]
  [ "$(output_value pushed)" = "false" ]
  # OSS main untouched -> external commit preserved
  [ "$(oss_branch_sha main)" = "$before" ]
  run oss_file main ext.go
  [ "$status" -eq 0 ]
}

@test "force reconciles once the external commit is absorbed into the subtree" {
  FORCE=true run bash "$SCRIPT"
  add_external_commit

  echo "v2" > "$PFX/app.go"
  git commit -qam "pro: bump to v2"
  FORCE=true run bash "$SCRIPT"
  [ "$status" -ne 0 ]   # diverged

  # Absorb the external content into the subtree (what sync-from-oss does),
  # bringing the subtree's content in line with OSS main.
  cp "$ROOT/ext/ext.go" "$PFX/ext.go"
  oss_file main app.go > "$PFX/app.go"
  git add -A && git commit -qm "pro: sync from oss"

  FORCE=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  [ "$(output_value diverged)" = "false" ]
  run oss_file main ext.go
  [ "$status" -eq 0 ]
}

@test "force with allow-divergent-force overrides the guard" {
  FORCE=true run bash "$SCRIPT"
  add_external_commit

  echo "v2" > "$PFX/app.go"
  git commit -qam "pro: bump to v2"
  FORCE=true ALLOW_DIVERGENT_FORCE=true run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  # override clobbers: external file is gone, subtree content wins
  run oss_file main ext.go
  [ "$status" -ne 0 ]
  [ "$(oss_file main app.go)" = "v2" ]
}

@test "force fails closed when the OSS remote cannot be queried" {
  # A transport/auth failure must not be mistaken for a missing branch (which
  # would permit an unguarded force push). ls-remote against a non-existent
  # remote errors, so the script must bail before pushing anything.
  OSS_REMOTE="$ROOT/does-not-exist.git" FORCE=true run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to query"* ]]
  [ "$(output_value pushed)" = "false" ]
  [ "$(output_value diverged)" = "false" ]
}

@test "missing required env fails" {
  unset SUBTREE_PREFIX
  FORCE=true run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

# --- split backend selection ----------------------------------------------
#
# git subtree split recurses one frame per commit and dies under dash on deep
# histories, so run.sh can split via git-filter-repo or via git-subtree-under-
# bash. Both must produce an identical mirror; SUBTREE_SPLIT_METHOD forces each.

@test "split via the git-subtree bash backend mirrors correctly" {
  SUBTREE_SPLIT_METHOD=subtree FORCE=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  [ "$(output_value diverged)" = "false" ]
  [ "$(oss_file main app.go)" = "v1" ]
}

@test "split via the git-filter-repo backend mirrors correctly" {
  if ! git filter-repo --version >/dev/null 2>&1; then
    skip "git-filter-repo not installed"
  fi
  SUBTREE_SPLIT_METHOD=filter-repo FORCE=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  [ "$(output_value diverged)" = "false" ]
  [ "$(oss_file main app.go)" = "v1" ]
}

@test "both split backends yield the same tree" {
  if ! git filter-repo --version >/dev/null 2>&1; then
    skip "git-filter-repo not installed"
  fi
  SUBTREE_SPLIT_METHOD=subtree FORCE=true run bash "$SCRIPT"
  sub_sha="$(output_value split-sha)"
  # Reset the OSS side so the second run is an independent first-push.
  git -C "$OSS_REMOTE" update-ref -d "$MARKER_REF" || true
  SUBTREE_SPLIT_METHOD=filter-repo FORCE=true run bash "$SCRIPT"
  fr_sha="$(output_value split-sha)"
  # Synthetic commit SHAs differ between backends, but the tree they publish
  # (the subtree content) must be identical.
  [ "$(git -C "$PRO" rev-parse "${sub_sha}^{tree}")" = "$(git -C "$PRO" rev-parse "${fr_sha}^{tree}")" ]
}

@test "unknown split method fails loudly" {
  SUBTREE_SPLIT_METHOD=bogus FORCE=true run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown SUBTREE_SPLIT_METHOD"* ]]
}

# auto must pin FORCE=false to git-subtree: a fast-forward-only push needs a
# history continuous with whatever produced the branch, and the two backends'
# synthetic histories are not interchangeable. FORCE mode force-pushes behind a
# tree guard, so there auto is free to prefer filter-repo. Both assertions only
# hold when filter-repo is present (otherwise auto trivially picks subtree).

@test "auto pins FORCE=false to the git-subtree backend even with filter-repo present" {
  if ! git filter-repo --version >/dev/null 2>&1; then
    skip "git-filter-repo not installed"
  fi
  FORCE=false BRANCH=v0.36 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"subtree-split-method: subtree-bash"* ]]
}

@test "auto prefers filter-repo for FORCE mode when available" {
  if ! git filter-repo --version >/dev/null 2>&1; then
    skip "git-filter-repo not installed"
  fi
  FORCE=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"subtree-split-method: filter-repo"* ]]
}

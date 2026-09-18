#!/usr/bin/env bats
# Unit tests for lib.sh apply_patch.
#
# What is pinned here is the fail-closed arm: git apply, handed a patch it can
# only partially read, applies the files it understood, prints "corrupt binary
# patch", and exits 0. Taking that rc at face value is how a replay commits a
# subset of a commit's content under the original message and trailer, so the
# helper has to classify it from the text.
#
# The export/import regression tests cannot reach this arm: with the diff now
# written to a file, git apply simply succeeds. Only a deliberately truncated
# patch gets there, which is why it is built by hand below.

load helpers

setup() {
  ROOT=$(mktemp -d); export ROOT
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_CONFIG_GLOBAL="$ROOT/gc"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  git config --file "$GIT_CONFIG_GLOBAL" user.useConfigOnly true
  # shellcheck disable=SC1090
  source "$BATS_TEST_DIRNAME/../lib.sh"

  REPO="$ROOT/r"
  git init -q "$REPO"
  cd "$REPO"
  # Two files, the binary last in diff order: a- sorts before z-.
  printf 'before\n' > a-notes.md
  write_binary z-diagram.png one
  git add . && git commit -qm base
  BASE=$(git rev-parse HEAD)

  printf 'after\n' > a-notes.md
  write_binary z-diagram.png two
  git add . && git commit -qm change
  CHANGE=$(git rev-parse HEAD)
}

teardown() { rm -rf "$ROOT"; }

# The bug's own shape: capture the diff through "$(...)", which strips the
# blank line terminating the last GIT binary patch, and re-add a single
# newline. Exactly what export.sh and import.sh used to do.
truncated_patch() {
  local p
  p="$(git diff-tree --no-commit-id -p --binary -M "$CHANGE")"
  printf '%s\n' "$p" > "$ROOT/truncated.patch"
}

@test "a patch git only partially reads fails instead of returning success" {
  truncated_patch
  git checkout -q "$BASE" -- .

  run apply_patch "$ROOT/truncated.patch" "$REPO"
  [ "$status" -eq "$APPLY_PATCH_CORRUPT" ]
}

@test "git's own corrupt-patch wording reaches the log" {
  # The classification greps git's text, so a git-side rewording must surface
  # as a failing assertion here rather than as a guard that silently stops
  # firing while every other test still passes.
  truncated_patch
  git checkout -q "$BASE" -- .

  run apply_patch "$ROOT/truncated.patch" "$REPO"
  [[ "$output" == *"corrupt binary patch"* ]]
}

@test "the partial apply the bug produced is not left staged" {
  # The point of failing: without it the caller stages and commits whatever git
  # did manage to apply. Assert the text file really was applied, i.e. the
  # apply was genuinely partial and not a clean refusal.
  truncated_patch
  git checkout -q "$BASE" -- .

  run apply_patch "$ROOT/truncated.patch" "$REPO"
  [ "$status" -ne 0 ]
  [ "$(cat "$REPO/a-notes.md")" = "after" ]
  # ...while the binary never moved. A caller that trusted rc=0 would commit
  # exactly this pair.
  [ "$(git -C "$REPO" hash-object z-diagram.png)" = "$(git -C "$REPO" rev-parse "${BASE}:z-diagram.png")" ]
}

@test "a whole patch applies cleanly and reports success" {
  git diff-tree --no-commit-id -p --binary -M "$CHANGE" > "$ROOT/whole.patch"
  git checkout -q "$BASE" -- .

  run apply_patch "$ROOT/whole.patch" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"corrupt"* ]]
  [[ "$output" != *"::error::"* ]]
}

@test "a real conflict is not reported as a corrupt patch" {
  # The two failure modes call for opposite handling, so the codes must differ:
  # a conflict is hand-resolved or re-anchored, an unreadable patch never is.
  git diff-tree --no-commit-id -p --binary -M "$CHANGE" -- a-notes.md > "$ROOT/text.patch"
  git checkout -q "$BASE" -- .
  printf 'something else entirely\n' > a-notes.md
  git add . && git commit -qm divergent

  run apply_patch "$ROOT/text.patch" "$REPO"
  [ "$status" -ne 0 ]
  [ "$status" -ne "$APPLY_PATCH_CORRUPT" ]
}

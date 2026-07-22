#!/usr/bin/env bats
# A squash-merged sync PR is a policy violation (it destroys per-commit
# authorship of external contributions on the monorepo base branch), but it
# must NOT corrupt the sync: OSS history is append-only and already holds the
# real commits, and the trailer state self-heals through the benign guard and
# the no-op skips. These tests pin that down for both squash variants.

load helpers

setup() {
  setup_fixture
}

teardown() {
  teardown_fixture
}

# Simulate the GitHub "Squash and merge" button: one commit on the base with
# the PR branch's combined diff and a caller-provided message.
squash_merge_pr_branch() {
  local msg="$1"
  (
    cd "$MONO"
    git switch -q main
    git merge --squash -q "automation/sync-from-oss-main"
    git commit -qm "$msg"
  )
}

@test "squash WITHOUT trailers self-heals: export benign+no-op, import re-skips" {
  external_commit ext1.go "one" "feat: alice first"
  external_commit ext2.go "two" "feat: alice second"
  bash "$IMPORT"

  # Worst case: the squash message loses the Oss-Commit trailers entirely.
  squash_merge_pr_branch "chore: sync from oss (#42)"

  # Export: the externals look unabsorbed (no trailers on main), but their
  # content is in staging, so the benign guard passes; the squash commit
  # itself has no Oss-Commit trailer, so it enters the replay range and must
  # be skipped as a no-op instead of duplicating content or failing.
  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value diverged)" = "false" ]
  [ "$(output_value exported-count)" = "0" ]
  [ "$(output_value pushed)" = "false" ]
  # OSS keeps the real authorship untouched (append-only mirror)
  [ "$(git -C "$OSS_REMOTE" log -1 --format=%an 'main^')" = "alice" ]

  # Import: resume falls back before the squash, re-walks both externals,
  # and skips each as a no-op; no duplicate replay commits.
  git -C "$MONO" switch -q main
  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  [ "$(output_value replayed-count)" = "0" ]

  # And normal operation continues: the next company commit exports cleanly.
  company_commit pkg/app.go "after-squash" "feat: company after squash" >/dev/null
  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value exported-count)" = "1" ]
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]
}

@test "squash WITH trailers in the body: resume takes the newest trailer" {
  E1=$(external_commit ext1.go "one" "feat: alice first")
  E2=$(external_commit ext2.go "two" "feat: alice second")
  bash "$IMPORT"

  # GitHub's default squash message concatenates the commit messages, so
  # both Oss-Commit trailers land in one commit body; the newest must win.
  squash_merge_pr_branch "chore: sync from oss (#42)

feat: alice first

Oss-Commit: $E1

feat: alice second

Oss-Commit: $E2"

  git -C "$MONO" switch -q main
  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value diverged)" = "false" ]
  [ "$(output_value exported-count)" = "0" ]
}

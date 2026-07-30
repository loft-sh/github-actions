#!/usr/bin/env bats
# A squash-merged sync PR is a policy violation (it destroys per-commit
# authorship of external contributions on the monorepo base branch), but it
# must NOT corrupt the sync: OSS history is append-only and already holds the
# real commits. These tests pin that down for every squash variant.
#
# The variant that matters most is the one GitHub actually produces: squash
# appends "Co-authored-by:" as a NEW paragraph, which orphans our Oss-Commit
# trailer from the block git's own %(trailers) parser reads. That silently
# froze the vcluster-pro import anchor, and the sync then hard-failed once a
# re-walked commit stopped applying as a no-op. Covered below by
# "GitHub-shaped squash" and "a later overlapping commit".

load helpers

setup() {
  setup_fixture
}

teardown() {
  teardown_fixture
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

@test "GitHub-shaped squash (Co-authored-by appended) keeps the anchor readable" {
  E1=$(external_commit ext1.go "one" "feat: alice first")
  bash "$IMPORT"

  # GitHub's squash-merge appends the co-author block as its own paragraph,
  # which pushes our trailer out of the paragraph git parses as trailers.
  squash_merge_pr_branch "feat: alice first (#42)

Oss-Commit: $E1

Co-authored-by: alice <alice@contributor.example>"

  # Premise: git's own trailer parser is blind to it.
  [ -z "$(git -C "$MONO" log -1 --format='%(trailers:key=Oss-Commit,valueonly)' main | tr -d '[:space:]')" ]

  git -C "$MONO" switch -q main
  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  [ "$(output_value replayed-count)" = "0" ]
  # The assertion that matters: the anchor resolved to E1, so nothing was
  # re-walked at all. A lost anchor also reports has-changes=false (the
  # re-walked commit applies as a no-op), which is exactly why the breakage
  # stayed invisible until a re-walked patch stopped applying.
  [ "$(output_value skipped-count)" = "0" ]
}

@test "GitHub-shaped squash then a later overlapping commit: import stays green" {
  # The production failure, end to end. Two externals edit the SAME file, both
  # sync PRs are squash-merged with a co-author, so neither trailer is in the
  # block git parses. Before the whole-message lookup the anchor fell back to
  # the seed, the importer re-walked the first external, and its patch no
  # longer applied because the second external's edit of those same lines was
  # already in staging: a hard conflict on content that was fully present.
  E1=$(external_commit pkg/app.go "first-external-version" "fix: first external edit")
  bash "$IMPORT"
  squash_merge_pr_branch "fix: first external edit (#4037) (#2113)

Oss-Commit: $E1

Co-authored-by: alice <alice@contributor.example>"

  E2=$(external_commit pkg/app.go "second-external-version" "test: follow-up on the same lines")
  git -C "$MONO" switch -q main
  bash "$IMPORT"
  squash_merge_pr_branch "test: follow-up on the same lines (#4123) (#2119)

Oss-Commit: $E2

Co-authored-by: alice <alice@contributor.example>"

  # Both externals are absorbed; the subtree matches OSS exactly.
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "main:$PFX")" ]

  git -C "$MONO" switch -q main
  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  [ "$(output_value replayed-count)" = "0" ]
  [ -z "$(output_value conflict-sha)" ]
}

@test "a lost trailer heals from content while pending commits still import" {
  # The case that would otherwise need an operator repair: the trailer recording
  # E1 is gone entirely, so no message scan can recover it. The subtree content
  # is the surviving evidence that E1 landed, and the anchor is derived from it.
  # Crucially, healing must not swallow E2: the anchor advances only as far as
  # the subtree content proves, and genuinely pending work is still replayed.
  E1=$(external_commit pkg/app.go "first-external-version" "fix: first external edit")
  bash "$IMPORT"
  squash_merge_pr_branch "chore: sync from oss (#42)"

  E2=$(external_commit pkg/app.go "second-external-version" "test: follow-up on the same lines")

  git -C "$MONO" switch -q main
  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ -z "$(output_value conflict-sha)" ]
  # Anchor healed over E1 ...
  [ "$(output_value healed-count)" = "1" ]
  # ... and E2 was still imported, with its authorship and trailer intact.
  [ "$(output_value replayed-count)" = "1" ]
  [ "$(output_value has-changes)" = "true" ]
  cd "$MONO"
  git switch -q automation/sync-from-oss-main
  [ "$(cat "$PFX/pkg/app.go")" = "second-external-version" ]
  [ "$(git log -1 --format=%an)" = "alice" ]
  [ "$(git log -1 --format=%B | grep '^Oss-Commit:' | awk '{print $2}')" = "$E2" ]
}

@test "an out-of-order trailer cannot drag the anchor backwards" {
  # Anchor selection takes the recorded import that reaches FARTHEST along OSS
  # history, not the one on the newest monorepo commit. Those differ whenever a
  # later commit records an EARLIER import: a hand-written re-import, a
  # backport, a repaired trailer. Newest-commit-wins would move the anchor back
  # and re-open the re-walk that the whole-message lookup closes.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  absorb_external
  E2=$(external_commit ext2.go "two" "feat: alice second")
  absorb_external

  # A later commit on main re-records the OLDER import.
  git -C "$MONO" commit -q --allow-empty -m "chore: re-record an earlier import

Oss-Commit: $E1"

  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  # Anchored at E2, nothing is re-walked. Anchored at E1, E2 gets re-walked and
  # skipped as a no-op, which is the silent-drift state this guards against.
  [ "$(output_value skipped-count)" = "0" ]
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

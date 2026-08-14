#!/usr/bin/env bats
# Tests for import.sh (external OSS commits -> monorepo subtree PR branch).

load helpers

setup() {
  setup_fixture
}

teardown() {
  teardown_fixture
}

@test "basic import: external commit replayed under the prefix with authorship and trailer" {
  E=$(external_commit ext.go "external" "feat: external contribution")

  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "true" ]
  [ "$(output_value replayed-count)" = "1" ]
  [ "$(output_value pr-branch)" = "automation/sync-from-oss-main" ]

  cd "$MONO"
  git switch -q automation/sync-from-oss-main
  [ "$(git log -1 --format=%s)" = "feat: external contribution" ]
  [ "$(git log -1 --format=%an)" = "alice" ]
  [ "$(git log -1 --format='%(trailers:key=Oss-Commit,valueonly)')" = "$E" ]
  [ "$(cat "$PFX/ext.go")" = "external" ]
  # pro files untouched
  [ "$(cat pro.txt)" = "pro-only" ]
}

@test "import skips commits we exported (loop guard)" {
  company_commit pkg/app.go "l1-company" "feat: company change" >/dev/null
  bash "$EXPORT"

  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  [ "$(output_value replayed-count)" = "0" ]
}

@test "healing over our own exports is not reported as a lost trailer" {
  # The steady state after any export: the OSS commits we just created are in the
  # subtree (that is where they came from) and carry Monorepo-Commit, never an
  # Oss-Commit trailer, so the anchor heals over them on the next import. That is
  # not trailer damage, and an annotation claiming it is fires after every export
  # and trains everyone to ignore the one that matters.
  company_commit pkg/app.go "l1-company" "feat: company change" >/dev/null
  company_commit pkg/other.go "more" "feat: second company change" >/dev/null
  bash "$EXPORT"

  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value healed-count)" = "2" ]
  [ "$(output_value healed-export-count)" = "2" ]
  [ "$(output_value healed-unrecorded-count)" = "0" ]
  [[ "$output" != *"::notice::"* ]]
  [[ "$output" == *"our own export"* ]]
}

@test "a mixed healed range separates our exports from unrecorded imports" {
  # Both causes at once, which is what production actually looks like: an import
  # whose trailer a squash dropped, then our own exports on top. The count that
  # drives the annotation must be the unrecorded one alone.
  external_commit ext1.go "one" "feat: alice first" >/dev/null
  bash "$IMPORT"
  squash_merge_pr_branch "chore: sync from oss (#42)"
  company_commit pkg/app.go "l1-company" "feat: company change" >/dev/null
  bash "$EXPORT"

  git -C "$MONO" switch -q main
  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value healed-count)" = "2" ]
  [ "$(output_value healed-export-count)" = "1" ]
  [ "$(output_value healed-unrecorded-count)" = "1" ]
  [[ "$output" == *"::notice::Anchor healed from content"* ]]
}

@test "exclusion: producer workflow edits are dropped from a mixed commit" {
  external_commit .github/workflows/release.yaml "producer-edit" "chore: producer only" >/dev/null
  # A genuinely mixed commit: excluded workflow + real code in one commit.
  git clone -q "$OSS_REMOTE" "$ROOT/mixed"
  (
    cd "$ROOT/mixed"
    echo "producer-edit-2" > .github/workflows/release.yaml
    echo "external" > ext.go
    git add . && git commit -qm "feat: mixed with code"
    git push -q origin main
  )

  EXCLUDE_PATHS=".github/workflows/release.yaml" run bash "$IMPORT"
  [ "$status" -eq 0 ]
  # producer-only commit skipped without a marker; mixed commit replayed
  # with the workflow path stripped
  [ "$(output_value replayed-count)" = "1" ]
  [ "$(output_value skipped-count)" = "1" ]

  cd "$MONO"
  git switch -q automation/sync-from-oss-main
  [ ! -e "$PFX/.github/workflows/release.yaml" ]
  [ "$(cat "$PFX/ext.go")" = "external" ]
}

@test "excluded-only commits are idempotently re-skipped" {
  external_commit .github/workflows/release.yaml "producer-edit" "chore: producer only" >/dev/null

  EXCLUDE_PATHS=".github/workflows/release.yaml" run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  [ "$(output_value skipped-count)" = "1" ]

  EXCLUDE_PATHS=".github/workflows/release.yaml" run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  [ "$(output_value skipped-count)" = "1" ]
}

@test "resume: after absorption only new externals are replayed" {
  external_commit ext.go "external" "feat: first external" >/dev/null
  absorb_external
  E2=$(external_commit ext2.go "external-2" "feat: second external")

  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value replayed-count)" = "1" ]
  cd "$MONO"
  git switch -q automation/sync-from-oss-main
  [ "$(git log -1 --format='%(trailers:key=Oss-Commit,valueonly)')" = "$E2" ]
}

@test "unexported company change survives an import (no snapshot revert)" {
  # Company commit not yet exported + external commit on a different file.
  company_commit pkg/company.go "company" "feat: unexported company change" >/dev/null
  external_commit ext.go "external" "feat: external contribution" >/dev/null

  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value replayed-count)" = "1" ]
  cd "$MONO"
  git switch -q automation/sync-from-oss-main
  # THE regression test vs snapshot projection: both changes present.
  [ "$(cat "$PFX/pkg/company.go")" = "company" ]
  [ "$(cat "$PFX/ext.go")" = "external" ]
}

@test "conflict: overlapping change fails closed with conflict-sha and a clean tree" {
  company_commit pkg/app.go "company-version" "feat: company edit" >/dev/null
  E=$(external_commit pkg/app.go "external-version" "fix: conflicting external edit")

  run bash "$IMPORT"
  [ "$status" -ne 0 ]
  [ "$(output_value conflict-sha)" = "$E" ]
  cd "$MONO"
  [ -z "$(git status --porcelain)" ]
}

@test "re-run rebuilds the PR branch idempotently" {
  external_commit ext.go "external" "feat: external contribution" >/dev/null

  bash "$IMPORT"
  first_tree=$(cd "$MONO" && git rev-parse "automation/sync-from-oss-main^{tree}")
  # A real re-run starts from a fresh checkout of the base branch.
  git -C "$MONO" switch -q main
  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value replayed-count)" = "1" ]
  [ "$(cd "$MONO" && git rev-parse "automation/sync-from-oss-main^{tree}")" = "$first_tree" ]
}

@test "seed: first run without trailers uses SEED_OSS_COMMIT" {
  # Strip the trailer state: reset main to before the seed-state commit, so
  # no Oss-Commit trailer exists anywhere on the branch.
  git -C "$MONO" reset -q --hard "$M0"
  external_commit ext.go "external" "feat: external contribution" >/dev/null

  run bash "$IMPORT"
  [ "$status" -ne 0 ]  # no trailer, no seed -> refuse
  # Assert the DIAGNOSIS, not just the exit code. A bare non-zero check also
  # passes when the script dies of an unbound variable before reaching this
  # branch, which is how a `set -u` crash hid here: the operator then gets a raw
  # bash error and no ::error:: annotation telling them to pass seed-oss-commit.
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"SEED_OSS_COMMIT"* ]]
  [[ "$output" != *"unbound variable"* ]]

  SEED_OSS_COMMIT="$O0" run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value replayed-count)" = "1" ]
}

@test "a seed pointing outside OSS history is rejected with a clear error" {
  external_commit ext.go "external" "feat: external contribution" >/dev/null
  # A monorepo commit is a valid object but not reachable from the OSS tip.
  SEED_OSS_COMMIT="$M0" run bash "$IMPORT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a commit reachable from OSS"* ]]
}

@test "the seed acts as a floor on a recorded anchor, not only a fallback" {
  # A recorded anchor exists and the operator seeds a LATER point: the seed wins,
  # so re-anchoring never requires rewriting history on the base branch.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  E2=$(external_commit ext2.go "two" "feat: alice second")

  SEED_OSS_COMMIT="$E1" run bash "$IMPORT"
  [ "$status" -eq 0 ]
  # Resumed from E1, so only E2 is replayed and E1 is never walked.
  [ "$(output_value replayed-count)" = "1" ]
  cd "$MONO"
  git switch -q automation/sync-from-oss-main
  [ "$(git log -1 --format=%B | grep '^Oss-Commit:' | awk '{print $2}')" = "$E2" ]
  [ ! -f "$PFX/ext1.go" ]
}

@test "merge commit on OSS fails closed" {
  git clone -q "$OSS_REMOTE" "$ROOT/mergesrc"
  (
    cd "$ROOT/mergesrc"
    git switch -qc feature
    echo "f" > f.go && git add . && git commit -qm "feat: on branch"
    git switch -q main
    echo "m" > m.go && git add . && git commit -qm "feat: on main"
    git merge -q --no-ff --no-edit feature
    git push -q origin main
  )

  run bash "$IMPORT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge commit"* ]]
}

@test "an annotated tag sha cannot win the anchor and swallow pending imports" {
  # cat-file -e and merge-base both peel a tag object, so an Oss-Commit value
  # naming a tag would resolve to a commit no trailer records and could win the
  # anchor. That failure is silent in the worst way: the pending externals are
  # neither replayed nor skipped nor counted, they just never arrive.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  E2=$(external_commit ext2.go "two" "feat: alice second")
  git -C "$ROOT/oss.git" tag -a v0.2.0 -m "release" "$E2"
  tag=$(git -C "$ROOT/oss.git" rev-parse v0.2.0)
  [ "$tag" != "$E2" ]
  # The action's own fetch does not pull tag objects; this is the case where the
  # monorepo happens to hold them, without which the probe proves nothing.
  git -C "$MONO" fetch -q "$OSS_REMOTE" 'refs/tags/*:refs/tags/*'
  git -C "$MONO" cat-file -e "$tag"

  git -C "$MONO" commit -q --allow-empty -m "chore: note the release

Oss-Commit: $tag"

  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "true" ]
  [ "$(output_value replayed-count)" = "2" ]
  [ "$(git -C "$MONO" show "automation/sync-from-oss-main:$PFX/ext1.go")" = "one" ]
  [ "$(git -C "$MONO" show "automation/sync-from-oss-main:$PFX/ext2.go")" = "two" ]
}

@test "no-op external (same change already in staging) is skipped, not a crash" {
  company_commit pkg/dup.go "same-content" "feat: company version" >/dev/null
  external_commit pkg/dup.go "same-content" "feat: external identical version" >/dev/null

  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  [ "$(output_value replayed-count)" = "0" ]
  [ "$(output_value skipped-count)" = "1" ]
  # idempotent: re-run from the base branch skips it again
  git -C "$MONO" switch -q main
  run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value skipped-count)" = "1" ]
}

@test "a tag sha seeded as the anchor is stored peeled, so re-runs settle" {
  # `git rev-parse v1.2.3` prints the tag object, which is the natural thing for
  # an operator to paste into seed-oss-commit. Accepting it is right; keeping it
  # is not. The anchor is compared against commit shas -- import's
  # "$RESUME" = "$OSS_TIP" nothing-to-do shortcut, health's anchor output -- and a
  # tag sha equals none of them, so the shortcut never fires and every run
  # rebuilds the PR branch to replay an empty range.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  git -C "$ROOT/oss.git" tag -a v0.3.0 -m "release" "$E1"
  tag=$(git -C "$ROOT/oss.git" rev-parse v0.3.0)
  [ "$tag" != "$E1" ]
  git -C "$MONO" fetch -q "$OSS_REMOTE" 'refs/tags/*:refs/tags/*'

  # Seeded at the tip: there is genuinely nothing left to import, and the
  # shortcut must say so rather than rebuilding the PR branch for an empty range.
  SEED_OSS_COMMIT="$tag" run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value has-changes)" = "false" ]
  [[ "$output" == *"nothing to import"* ]]
  # The shortcut is the only thing that skips the branch switch, so its absence
  # is observable: an unresolved tag sha leaves this branch behind.
  ! git -C "$MONO" rev-parse --verify --quiet "$PR_BRANCH" >/dev/null
}

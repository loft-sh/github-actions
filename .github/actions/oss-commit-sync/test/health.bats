#!/usr/bin/env bats
# The health direction is read-only: it reports drift that a green export or
# import run does not surface, and must never commit, push, or fail the caller.

load helpers

setup() {
  setup_fixture
  HEALTH="$BATS_TEST_DIRNAME/../health.sh"
  export GITHUB_STEP_SUMMARY="$ROOT/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
}

teardown() {
  teardown_fixture
}

squash_merge_pr_branch() {
  local msg="$1"
  (
    cd "$MONO"
    git switch -q main
    git merge --squash -q "automation/sync-from-oss-main"
    git commit -qm "$msg"
  )
}

@test "a converged sync reports healthy" {
  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value converged)" = "true" ]
  [ "$(output_value anchor)" = "$O0" ]
  [ "$(output_value stale-anchor)" = "false" ]
  [ "$(output_value pending-count)" = "0" ]
  [ "$(output_value squashed-trailer-count)" = "0" ]
}

@test "pending externals are counted, not flagged as staleness" {
  external_commit ext.go "one" "feat: alice first" >/dev/null
  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value converged)" = "false" ]
  [ "$(output_value pending-count)" = "1" ]
  [ "$(output_value stale-anchor)" = "false" ]
  [ -z "$(output_value suggested-anchor)" ]
}

@test "trailers lagging the content are reported as lost provenance, not an outage" {
  # Absorb an external, then drop the trailer entirely: the content is in
  # staging but nothing records it. The import heals from content, so the sync
  # is fine; what is lost is the recorded provenance of that commit.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  bash "$IMPORT"
  squash_merge_pr_branch "chore: sync from oss (#42)"

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value stale-anchor)" = "true" ]
  [ "$(output_value recorded-anchor)" = "$O0" ]
  [ "$(output_value anchor)" = "$E1" ]
  [ "$(output_value redundant-count)" = "1" ]
  [ "$(output_value pending-count)" = "0" ]
  # Reported as a notice, not a warning: nothing is broken.
  [[ "$output" == *"heals"* ]]
}

@test "the healed anchor stops at the newest commit the subtree matches" {
  # Absorbed-but-unrecorded, then a genuinely pending commit. The anchor may
  # advance to the former only; advancing past the pending commit would drop it
  # from the import silently.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  bash "$IMPORT"
  squash_merge_pr_branch "chore: sync from oss (#42)"
  external_commit ext2.go "two" "feat: alice second (pending)" >/dev/null

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value stale-anchor)" = "true" ]
  [ "$(output_value anchor)" = "$E1" ]
  [ "$(output_value pending-count)" = "1" ]
}

@test "a squash-orphaned trailer is reported even though the sync still reads it" {
  E1=$(external_commit ext1.go "one" "feat: alice first")
  bash "$IMPORT"
  squash_merge_pr_branch "feat: alice first (#42)

Oss-Commit: $E1

Co-authored-by: alice <alice@contributor.example>"

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  # The anchor is intact, so the sync is functionally fine ...
  [ "$(output_value anchor)" = "$E1" ]
  [ "$(output_value stale-anchor)" = "false" ]
  # ... but the merge policy was violated and authorship was collapsed.
  [ "$(output_value squashed-trailer-count)" = "1" ]
  [[ "$output" == *"Rebase and merge"* ]]
}

@test "health never mutates the repository" {
  external_commit ext.go "one" "feat: alice first" >/dev/null
  before_head="$(git -C "$MONO" rev-parse HEAD)"
  before_oss="$(oss_tip)"
  before_branches="$(git -C "$MONO" for-each-ref --format='%(refname)' refs/heads)"

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(git -C "$MONO" rev-parse HEAD)" = "$before_head" ]
  [ "$(oss_tip)" = "$before_oss" ]
  [ "$(git -C "$MONO" for-each-ref --format='%(refname)' refs/heads)" = "$before_branches" ]
  [ -z "$(git -C "$MONO" status --porcelain)" ]
}

@test "a missing anchor is warned about, not fatal" {
  git -C "$MONO" reset -q --hard "$M0"
  external_commit ext.go "one" "feat: alice first" >/dev/null

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ -z "$(output_value anchor)" ]
  [[ "$output" == *"seed-oss-commit"* ]]
}

@test "the step summary records the findings" {
  external_commit ext.go "one" "feat: alice first" >/dev/null
  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  grep -q "OSS sync health" "$GITHUB_STEP_SUMMARY"
  grep -q "Commits pending import | 1" "$GITHUB_STEP_SUMMARY"
}

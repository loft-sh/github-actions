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
  [ "$(output_value redundant-unrecorded-count)" = "1" ]
  [ "$(output_value redundant-export-count)" = "0" ]
  [ "$(output_value pending-count)" = "0" ]
  # Reported as a notice, not a warning: nothing is broken.
  [[ "$output" == *"heals"* ]]
}

@test "the anchor trailing our own exports is not staleness" {
  # The anchor lags by design after every export: the OSS commits we created
  # carry Monorepo-Commit and never an Oss-Commit trailer, so nothing records
  # them as imports and nothing should. Flagging this would put a permanent lag
  # on a healthy sync and bury the unrecorded-import case underneath it.
  company_commit pkg/app.go "l1-company" "feat: company change" >/dev/null
  bash "$EXPORT"

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value converged)" = "true" ]
  [ "$(output_value redundant-count)" = "1" ]
  [ "$(output_value redundant-export-count)" = "1" ]
  [ "$(output_value redundant-unrecorded-count)" = "0" ]
  [ "$(output_value stale-anchor)" = "false" ]
  [ -z "$(output_value suggested-anchor)" ]
  [ "$(output_value squashed-trailer-count)" = "0" ]
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

@test "a squash whose last trailer stays in the block still reports the orphaned ones" {
  # No Co-authored-by paragraph, so git parses the LAST Oss-Commit fine and an
  # emptiness test scores this commit clean. E1's trailer is orphaned above it
  # all the same, which is the exact shape that deadlocked the export.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  E2=$(external_commit ext2.go "two" "feat: alice second")
  bash "$IMPORT"
  squash_merge_pr_branch "chore: sync from oss (#42)

feat: alice first

Oss-Commit: $E1

feat: alice second

Oss-Commit: $E2"

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  # Git's own parser sees E2, so the anchor is intact and the sync is fine ...
  [ "$(output_value anchor)" = "$E2" ]
  [ "$(output_value stale-anchor)" = "false" ]
  # ... but the squash collapsed authorship and hid E1's record.
  [ "$(output_value squashed-trailer-count)" = "1" ]
  [[ "$output" == *"Rebase and merge"* ]]
}

@test "a hex line quoted in a commit body is not reported as a squash" {
  # The scan reads the whole message by design, so prose at column 0 reaches the
  # comparison. Counting it would tell a maintainer who rebase-merged correctly
  # that they squashed, which is worse than missing a real one.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  bash "$IMPORT"
  squash_merge_pr_branch "feat: alice first (#42)

Reviewers asked why the trailer below looks like this:
Oss-Commit: 1111111111111111111111111111111111111111

Oss-Commit: $E1"

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  # The fabricated sha is no OSS commit, so nothing was orphaned.
  [ "$(output_value squashed-trailer-count)" = "0" ]
  [ "$(output_value degraded)" = "false" ]
  [[ "$output" != *"Rebase and merge"* ]]
}

@test "an annotated tag sha in a commit body is not reported as a squash" {
  # merge-base --is-ancestor peels a tag object to its commit, so an unguarded
  # ancestry test would call a tag sha a lost record even though no trailer names
  # that commit. Same type confusion the export guard already rejects.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  git -C "$ROOT/oss.git" tag -a v0.1.0 -m "release" "$E1"
  tag=$(git -C "$ROOT/oss.git" rev-parse v0.1.0)
  [ "$tag" != "$E1" ]
  # The monorepo must actually hold the tag object, or rev-parse fails on it for
  # the wrong reason and this pins nothing.
  git -C "$MONO" fetch -q "$OSS_REMOTE" 'refs/tags/*:refs/tags/*'
  git -C "$MONO" cat-file -e "$tag"
  bash "$IMPORT"
  squash_merge_pr_branch "feat: alice first (#42)

Tagged as v0.1.0, whose object is:
Oss-Commit: $tag

Oss-Commit: $E1"

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value squashed-trailer-count)" = "0" ]
  [ "$(output_value degraded)" = "false" ]
}

@test "a failing ancestry test degrades instead of reporting a clean policy" {
  # rc 1 means "not in OSS history"; anything else is git failing. Collapsing the
  # two would let a broken merge-base issue a clean bill of health.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  E2=$(external_commit ext2.go "two" "feat: alice second")
  bash "$IMPORT"
  squash_merge_pr_branch "chore: sync from oss (#42)

Oss-Commit: $E1

Oss-Commit: $E2"

  real_git="$(command -v git)"
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/git" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    merge-base) exit 128 ;;
  esac
done
exec "$real_git" "\$@"
WRAP
  chmod +x "$ROOT/bin/git"

  PATH="$ROOT/bin:$PATH" run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
  [ "$(output_value degraded)" = "true" ]
  [[ "$output" == *"Could not test whether"* ]]
}

@test "each commit is judged against its own trailer block" {
  # The scan is walked in one pass and grouped by sha, so a group boundary that
  # leaked would judge one commit's values against another's block: either an
  # orphan attributed to the clean commit, or both counted from one violation.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  bash "$IMPORT"
  squash_merge_pr_branch "feat: alice first (#42)

Oss-Commit: $E1

Co-authored-by: alice <alice@contributor.example>"
  squashed_sha=$(git -C "$MONO" rev-parse HEAD)

  # A later, properly recorded import on top: one carrier per commit, in-block.
  E2=$(external_commit ext2.go "two" "feat: alice second")
  absorb_external

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value squashed-trailer-count)" = "1" ]
  [[ "$output" == *"$squashed_sha"* ]]
  [[ "$output" != *"$(git -C "$MONO" rev-parse HEAD)"* ]]
}

@test "the oldest trailer-carrying commit is still counted" {
  # Groups close when the next sha arrives, so the last group in log order (the
  # oldest commit) is only ever counted by the flush after the loop. Dropping
  # that flush loses a real violation silently.
  E1=$(external_commit ext1.go "one" "feat: alice first")
  git -C "$MONO" reset -q --hard "$M0"
  # The only carrier on the branch, and its value sits outside git's block
  # because the message ends in prose.
  git -C "$MONO" commit -q --allow-empty -m "chore: sync from oss (#42)

Oss-Commit: $E1

Discussion continued after the merge."

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value squashed-trailer-count)" = "1" ]
  [[ "$output" == *"Rebase and merge"* ]]
}

@test "a rebase-merged import reports no squash-orphaned trailers" {
  # The negative side of the set comparison: one trailer per commit, inside the
  # block, must never be counted.
  external_commit ext1.go "one" "feat: alice first" >/dev/null
  absorb_external

  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [ "$(output_value squashed-trailer-count)" = "0" ]
  [ "$(output_value degraded)" = "false" ]
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

@test "an unreachable OSS remote warns and exits 0, never reds the caller" {
  # The most likely real failure (network, expired token, renamed branch). An
  # advisory check must not block a push to the base branch over it.
  OSS_REMOTE="$ROOT/does-not-exist.git" run bash "$HEALTH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" != *"::error::"* ]]
}

@test "a failing git producer degrades instead of reporting a clean backlog" {
  external_commit ext.go "one" "feat: alice first" >/dev/null

  # Fails ONLY diff-tree, so the outer rev-list still succeeds and the loop runs.
  # That isolates the per-commit producer: unguarded, its empty output reads as
  # "touches only excluded paths" and drops the commit from the backlog with no
  # degraded signal, so health reports pending-count=0 because git broke.
  # The real binary is resolved to an absolute path FIRST, otherwise the shim
  # re-resolves `git` through the patched PATH and recurses forever.
  real_git="$(command -v git)"
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/git" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    diff-tree) exit 128 ;;
  esac
done
exec "$real_git" "\$@"
WRAP
  chmod +x "$ROOT/bin/git"

  PATH="$ROOT/bin:$PATH" run bash "$HEALTH"
  # Never fails the caller ...
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
  # ... but says so, instead of issuing a clean bill of health it cannot support.
  [ "$(output_value degraded)" = "true" ]
  [[ "$output" == *"::warning::"* ]]
}

@test "the step summary records the findings" {
  external_commit ext.go "one" "feat: alice first" >/dev/null
  run bash "$HEALTH"
  [ "$status" -eq 0 ]
  grep -q "OSS sync health" "$GITHUB_STEP_SUMMARY"
  grep -q "Commits pending import | 1" "$GITHUB_STEP_SUMMARY"
}

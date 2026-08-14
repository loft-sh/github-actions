#!/usr/bin/env bats
# Tests for export.sh (monorepo subtree -> OSS).

load helpers

setup() {
  setup_fixture
}

teardown() {
  teardown_fixture
}

@test "basic export: one company commit becomes one OSS commit with authorship and trailer" {
  C=$(company_commit pkg/app.go "l1-changed" "feat: company change")

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  [ "$(output_value exported-count)" = "1" ]

  [ "$(git -C "$OSS_REMOTE" log -1 --format=%s main)" = "feat: company change" ]
  [ "$(git -C "$OSS_REMOTE" log -1 --format=%an main)" = "dev" ]
  [ "$(git -C "$OSS_REMOTE" log -1 --format='%(trailers:key=Monorepo-Commit,valueonly)' main)" = "$C" ]
  [ "$(oss_file pkg/app.go)" = "l1-changed" ]
}

@test "multiple commits export in order" {
  company_commit pkg/a.go "a" "feat: first"
  company_commit pkg/b.go "b" "feat: second"

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value exported-count)" = "2" ]
  [ "$(git -C "$OSS_REMOTE" log --format=%s -2 main | tac)" = "feat: first
feat: second" ]
}

@test "no-op run: nothing new pushes nothing and succeeds" {
  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "false" ]
  [ "$(output_value exported-count)" = "0" ]
}

@test "commits outside the subtree are not exported" {
  (cd "$MONO" && echo "pro-change" > pro.txt && git commit -qam "feat: pro only")

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "false" ]
}

@test "guard: unabsorbed external commit fails closed with diverged=true" {
  external_commit ext.go "external" "feat: external contribution"
  before=$(oss_tip)
  company_commit pkg/app.go "l1-company" "feat: company change"

  run bash "$EXPORT"
  [ "$status" -ne 0 ]
  [ "$(output_value diverged)" = "true" ]
  # nothing was pushed, nothing destroyed
  [ "$(oss_tip)" = "$before" ]
  [ "$(oss_file ext.go)" = "external" ]
}

@test "export after absorption: skips imported commit, keeps external content, trees converge" {
  E=$(external_commit ext.go "external" "feat: external contribution")
  absorb_external
  C=$(company_commit pkg/app.go "l1-company" "feat: company change")

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  # only the company commit was replayed; the absorbed one was skipped
  [ "$(output_value exported-count)" = "1" ]
  [ "$(oss_file ext.go)" = "external" ]
  [ "$(oss_file pkg/app.go)" = "l1-company" ]
  # convergence: OSS tree == staging tree
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]
}

@test "interleaving (C1, absorb E, C2): no revert/reapply churn on OSS" {
  # C1 lands before the external commit is absorbed.
  C1=$(company_commit pkg/c1.go "c1" "feat: c1")
  E=$(external_commit ext.go "external" "feat: external contribution")
  absorb_external
  C2=$(company_commit pkg/c2.go "c2" "feat: c2")

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value exported-count)" = "2" ]
  # THE regression test vs snapshot projection: the intermediate OSS commit
  # (C1's replay) must NOT revert the external file.
  c1_replay=$(git -C "$OSS_REMOTE" rev-parse main~1)
  run git -C "$OSS_REMOTE" show "$c1_replay:ext.go"
  [ "$status" -eq 0 ]
  [ "$output" = "external" ]
  # final tree converges
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]
}

@test "seeding: OSS branch without trailers requires and uses the seed pair" {
  # Rebuild the OSS remote without a trailer on the seed commit.
  rm -rf "$OSS_REMOTE" "$ROOT/ossseed"
  git init -q --bare "$OSS_REMOTE"
  git init -q "$ROOT/ossseed"
  (
    cd "$ROOT/ossseed"
    git checkout -q -b main
    mkdir -p pkg && printf 'l1\nl2\nl3\n' > pkg/app.go
    git add . && git commit -qm "pre-migration oss"
    git push -q "$OSS_REMOTE" main
  )
  seed_oss=$(oss_tip)
  company_commit pkg/app.go "l1-post-seed" "feat: post-seed change"

  run bash "$EXPORT"
  [ "$status" -ne 0 ]  # no trailer, no seed -> refuse

  SEED_MONOREPO_COMMIT="$M0" SEED_OSS_COMMIT="$seed_oss" run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value exported-count)" = "1" ]
  [ "$(oss_file pkg/app.go)" = "l1-post-seed" ]
}

@test "align-tree: tree drift fails without it, converges append-only with it" {
  # Simulate migration state: OSS still carries a producer workflow that the
  # staging tree does not have.
  git clone -q "$OSS_REMOTE" "$ROOT/drift"
  (
    cd "$ROOT/drift"
    mkdir -p .github/workflows
    echo "producer" > .github/workflows/release.yaml
    git add . && git commit -qm "chore: producer workflow (oss-only)

Monorepo-Commit: $M0"
    git push -q origin main
  )
  before=$(oss_tip)

  run bash "$EXPORT"
  [ "$status" -ne 0 ]  # assertion catches the drift
  [ "$(oss_tip)" = "$before" ]

  ALIGN_TREE=true run bash "$EXPORT"
  [ "$status" -eq 0 ]
  # append-only: previous tip is still the parent chain, file is gone
  git -C "$OSS_REMOTE" merge-base --is-ancestor "$before" main
  run oss_file .github/workflows/release.yaml
  [ "$status" -ne 0 ]
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]
}

@test "merge commit in the export range fails closed" {
  (
    cd "$MONO"
    git switch -qc feature
    company_commit pkg/f.go "f" "feat: on branch" >/dev/null
    git switch -q main
    company_commit pkg/g.go "g" "feat: on main" >/dev/null
    git merge -q --no-ff --no-edit feature
  )

  run bash "$EXPORT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge commit"* ]]
}

@test "new release branch: created on OSS anchored at the exported branch point" {
  C=$(company_commit pkg/app.go "l1-v2" "feat: pre-branch change")
  bash "$EXPORT"  # main is synced through C

  (
    cd "$MONO"
    git switch -qc v0.99
    company_commit pkg/rel.go "rel" "fix: release-line only" >/dev/null
  )

  BRANCH=v0.99 run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  # branch exists, contains the release commit, and its parent is main's tip
  [ "$(git -C "$OSS_REMOTE" log -1 --format=%s v0.99)" = "fix: release-line only" ]
  [ "$(git -C "$OSS_REMOTE" rev-parse v0.99~1)" = "$(git -C "$OSS_REMOTE" rev-parse main)" ]
  [ "$(git -C "$OSS_REMOTE" rev-parse 'v0.99^{tree}')" = "$(git -C "$MONO" rev-parse "v0.99:$PFX")" ]
}

@test "existing release branch: append is fast-forward" {
  bash "$EXPORT"
  (cd "$MONO" && git switch -qc v0.99)
  BRANCH=v0.99 bash "$EXPORT"
  before=$(git -C "$OSS_REMOTE" rev-parse v0.99)

  (cd "$MONO" && git switch -q v0.99)
  company_commit pkg/rel.go "rel-2" "fix: backport" >/dev/null

  BRANCH=v0.99 run bash "$EXPORT"
  [ "$status" -eq 0 ]
  git -C "$OSS_REMOTE" merge-base --is-ancestor "$before" v0.99
  [ "$(git -C "$OSS_REMOTE" log -1 --format=%s v0.99)" = "fix: backport" ]
}

@test "prefix-sharing sibling directory does not leak into the export (--relative boundary)" {
  # A commit touching both the subtree and a string-prefix sibling
  # (vcluster-values) must export only the subtree half.
  (
    cd "$MONO"
    mkdir -p "${PFX}-values"
    echo "sibling" > "${PFX}-values/values.yaml"
    echo "l1-mixed" > "$PFX/pkg/app.go"
    git add . && git commit -qm "feat: mixed subtree + sibling commit"
  )

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value exported-count)" = "1" ]
  [ "$(oss_file pkg/app.go)" = "l1-mixed" ]
  # the sibling file must not appear anywhere in the OSS tree
  run git -C "$OSS_REMOTE" show "main:values.yaml"
  [ "$status" -ne 0 ]
  run git -C "$OSS_REMOTE" show "main:-values/values.yaml"
  [ "$status" -ne 0 ]
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]
}

@test "identical change on both sides: benign guard lets export proceed and converge" {
  # Company commit and an external commit make the same change; the import
  # skipped the external as a no-op (no trailer), so the guard must classify
  # it as benign instead of reporting divergence forever.
  company_commit pkg/dup.go "same-content" "feat: company version" >/dev/null
  external_commit pkg/dup.go "same-content" "feat: external identical version" >/dev/null

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value diverged)" = "false" ]
  # the company commit replays as a no-op (content already on OSS via the
  # external commit), so nothing needs pushing and the trees still converge
  [ "$(output_value pushed)" = "false" ]
  [ "$(output_value exported-count)" = "0" ]
  [ "$(oss_file pkg/dup.go)" = "same-content" ]
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]
}

@test "excluded-only external commit neither blocks the guard nor fails the assertion" {
  external_commit .github/workflows/release.yaml "producer-edit" "chore: oss-only workflow" >/dev/null
  company_commit pkg/app.go "l1-post-excluded" "feat: company change" >/dev/null

  EXCLUDE_PATHS=".github/workflows/release.yaml" run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value diverged)" = "false" ]
  [ "$(output_value pushed)" = "true" ]
  # the excluded file stays on OSS untouched; the mirrored content converges
  [ "$(oss_file .github/workflows/release.yaml)" = "producer-edit" ]
  [ "$(oss_file pkg/app.go)" = "l1-post-excluded" ]
}

@test "genuinely divergent external still fails closed despite the benign check" {
  external_commit pkg/app.go "external-different-content" "fix: real external change" >/dev/null
  company_commit pkg/other.go "x" "feat: company change" >/dev/null

  run bash "$EXPORT"
  [ "$status" -ne 0 ]
  [ "$(output_value diverged)" = "true" ]
}

@test "migration: align-tree removes excluded-path leftovers and seeds the trailer" {
  # Pre-migration OSS carries a producer workflow that staging does not have,
  # the exclude list covers it, and OSS has no trailers yet. align-tree must
  # act on this state even though the only drift is in excluded paths: if
  # the exclude-aware assertion also gated the alignment, this run would be
  # a green no-op that deletes nothing and seeds no trailer, leaving every
  # subsequent export unable to find a resume point.
  rm -rf "$OSS_REMOTE" "$ROOT/ossseed"
  git init -q --bare "$OSS_REMOTE"
  git init -q "$ROOT/ossseed"
  (
    cd "$ROOT/ossseed"
    git checkout -q -b main
    mkdir -p pkg .github/workflows
    printf 'l1\nl2\nl3\n' > pkg/app.go
    echo "producer" > .github/workflows/release.yaml
    git add . && git commit -qm "pre-migration oss"
    git push -q "$OSS_REMOTE" main
  )
  seed_oss=$(oss_tip)

  # Run with NO git identity in the environment. CI runners have no GECOS
  # name for git to derive an ident from, so the alignment commit-tree dies
  # with "empty ident name" unless the action supplies author defaults; the
  # fixture's exported idents must not mask that.
  SEED_MONOREPO_COMMIT="$M0" SEED_OSS_COMMIT="$seed_oss" \
    EXCLUDE_PATHS=".github/workflows/release.yaml" ALIGN_TREE=true \
    run env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value pushed)" = "true" ]
  # the alignment commit deleted the excluded leftover and seeded the trailer
  run oss_file .github/workflows/release.yaml
  [ "$status" -ne 0 ]
  [ -n "$(git -C "$OSS_REMOTE" log -1 --format='%(trailers:key=Monorepo-Commit,valueonly)' main)" ]
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]

  # and the seeded trailer makes the next run self-sufficient (no seeds)
  company_commit pkg/app.go "post-migration" "feat: first post-migration change" >/dev/null
  EXCLUDE_PATHS=".github/workflows/release.yaml" run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value exported-count)" = "1" ]
  [ "$(oss_file pkg/app.go)" = "post-migration" ]
}

@test "align-tree refuses to overwrite an external absorbed only outside the trailer block" {
  # The whole-message scan reads an Oss-Commit line anywhere, which is what
  # rescues a squash-orphaned trailer. That evidence keeps the export moving; it
  # must not authorise align-tree to delete the commit's content from OSS, since
  # "never absorbed" and "absorbed then superseded" look identical in content.
  E1=$(external_commit pkg/app.go "external-only-content" "feat: alice never imported")
  E2=$(external_commit ext2.go "two" "feat: alice second")
  bash "$IMPORT" >/dev/null
  git -C "$MONO" switch -q main
  # Records E2 in git's block, and E1 only on a line above it.
  git -C "$MONO" commit -q --allow-empty -m "chore: absorb the second

Note: still pending is
Oss-Commit: $E1

Oss-Commit: $E2"

  ALIGN_TREE=true run bash "$EXPORT"
  [ "$status" -eq 1 ]
  [ "$(output_value pushed)" = "false" ]
  [ "$(output_value loose-absorption)" = "true" ]
  # Not diverged: these commits ARE absorbed, and a caller wired to the documented
  # meaning of diverged would dispatch an import that has nothing to replay.
  [ "$(output_value diverged)" = "false" ]
  [[ "$output" == *"align-tree would overwrite"* ]]
  [[ "$output" == *"$E1"* ]]
  [[ "$output" == *"cannot clear this"* ]]
  # The contributor's commit is still on the mirror.
  [ "$(oss_file pkg/app.go)" = "external-only-content" ]
}

@test "align-tree still runs when the trees already agree despite weak evidence" {
  # The gate belongs at the alignment commit, not at the guard: with nothing to
  # align there is nothing to delete, and failing here would make align-tree
  # unusable forever on any branch that ever took a squash-merged import.
  E1=$(external_commit pkg/app.go "banner" "feat: add banner")
  E2=$(external_commit pkg/app.go "banner-trimmed" "revert: most of the banner")
  bash "$IMPORT" >/dev/null
  squash_merge_pr_branch "chore: sync from oss (#2177)

Oss-Commit: $E1

Oss-Commit: $E2

Co-authored-by: alice <alice@contributor.example>"

  # Premise: E1 is loosely absorbed and its content is gone, but the trees match.
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]

  ALIGN_TREE=true run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value loose-absorption)" = "true" ]
  [[ "$output" != *"::error::"* ]]
}

@test "a trailer only git's parser accepts still counts as absorbed" {
  # git reads "Oss-Commit:<sha>" with no space, and uppercase hex, while the
  # whole-message scan requires a lowercase hex value after "key: ". A record git
  # sees perfectly must not read as unabsorbed, or the deadlock returns by a third
  # road, with the content fallback unable to help once E1 is superseded.
  E1=$(external_commit pkg/app.go "banner" "feat: add banner")
  E2=$(external_commit pkg/app.go "banner-trimmed" "revert: most of the banner")
  bash "$IMPORT" >/dev/null
  # Squash-merged, so the branch's own well-formed trailers never reach main and
  # these two lines are the ONLY record. Both are forms the scan cannot read.
  squash_merge_pr_branch "chore: sync from oss (#42)

Oss-Commit:$(echo "$E1" | tr 'a-f' 'A-F')
Oss-Commit:$E2"

  # Premise: E1's content is superseded, so only the record can prove absorption.
  [ "$(cat "$MONO/$PFX/pkg/app.go")" = "banner-trimmed" ]

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value diverged)" = "false" ]
  [[ "$output" != *"not yet absorbed"* ]]
}

@test "align-tree proceeds when the loose external's content is present" {
  # Weak evidence only matters if alignment could delete something. Here the
  # import applied E1's content, so there is nothing to lose and the run must not
  # be blocked: otherwise align-tree is unusable after any squashed import.
  E1=$(external_commit pkg/app.go "alice-content" "feat: alice change")
  bash "$IMPORT" >/dev/null
  squash_merge_pr_branch "feat: alice change (#42)

Oss-Commit: $E1

Co-authored-by: alice <alice@contributor.example>"
  [ "$(cat "$MONO/$PFX/pkg/app.go")" = "alice-content" ]

  # Something for alignment to actually do, in an excluded path.
  external_commit .github/workflows/release.yaml "oss-only" "chore: oss-only workflow" >/dev/null

  EXCLUDE_PATHS=".github/workflows/release.yaml" ALIGN_TREE=true run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value loose-absorption)" = "false" ]
  [[ "$output" != *"align-tree would overwrite"* ]]
}

@test "a trailer value that is not a sha cannot red the export" {
  # Block values reach rev-parse unfiltered unless they are shape-checked, and
  # reflog syntax exits 128, which the resolver escalates into a failed run: one
  # such line anywhere in the range would break every export from then on.
  company_commit pkg/app.go "company" "feat: company change" >/dev/null
  git -C "$MONO" commit -q --allow-empty -m "chore: a human wrote nonsense

Oss-Commit: @{9999}"

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"git failed while resolving"* ]]
  [ "$(output_value exported-count)" = "1" ]
}

@test "an external absorbed outside the trailer block still exports without align-tree" {
  # The squash rescue itself must keep working: the guard passes, the run notes
  # the weak evidence, and the convergence assertion stays the backstop.
  E1=$(external_commit pkg/app.go "banner" "feat: add banner")
  E2=$(external_commit pkg/app.go "banner-trimmed" "revert: most of the banner")
  bash "$IMPORT" >/dev/null
  squash_merge_pr_branch "chore: sync from oss (#2177)

Oss-Commit: $E1

Oss-Commit: $E2

Co-authored-by: alice <alice@contributor.example>"

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value diverged)" = "false" ]
  [[ "$output" == *"absorbed only via an Oss-Commit line outside git trailer block"* ]]
}

@test "a folded trailer value is not strong absorption evidence" {
  # git keeps a folded value as several physical lines unless unfold is asked for,
  # so reading it line-wise would take the sha off the first line and treat a
  # commit nobody recorded as block-recorded, which is what align-tree trusts.
  E1=$(external_commit pkg/app.go "external-only-content" "feat: alice never imported")
  company_commit pkg/other.go "company" "feat: company change" >/dev/null
  git -C "$MONO" commit -q --allow-empty -m "chore: not a record at all

Oss-Commit:$E1
  this was not an absorption record"

  ALIGN_TREE=true run bash "$EXPORT"
  [ "$status" -eq 1 ]
  # Not absorbed at all: the folded value is no record, by either reading.
  [ "$(output_value diverged)" = "true" ]
  [ "$(output_value pushed)" = "false" ]
  [[ "$output" == *"not yet absorbed"* ]]
  [ "$(oss_file pkg/app.go)" = "external-only-content" ]
}

@test "loose-absorption is reported even when the run also diverges" {
  # Two findings in one run: the divergence exit must not swallow the other one.
  E1=$(external_commit pkg/app.go "banner" "feat: add banner")
  E2=$(external_commit pkg/app.go "banner-trimmed" "revert: most of the banner")
  bash "$IMPORT" >/dev/null
  squash_merge_pr_branch "chore: sync from oss (#42)

Oss-Commit: $E1

Oss-Commit: $E2

Co-authored-by: alice <alice@contributor.example>"
  # And now a genuinely unabsorbed external on top.
  external_commit ext9.go "pending" "feat: alice pending" >/dev/null

  run bash "$EXPORT"
  [ "$status" -eq 1 ]
  [ "$(output_value diverged)" = "true" ]
  [ "$(output_value loose-absorption)" = "true" ]
}

@test "a commit recorded only in git's laxer form is not replayed back to OSS" {
  # The guard and the loop guard must agree about the same trailer line. If the
  # guard counts a commit as absorbed but the loop does not count it as
  # OSS-originated, its diff is replayed and content the mirror already moved past
  # comes back, authored by the contributor.
  E1=$(external_commit pkg/app.go "banner" "feat: add banner")
  bash "$IMPORT" >/dev/null
  # Sole record, in a form only git's own parser reads (no space after the key).
  squash_merge_pr_branch "chore: sync from oss (#1)

Oss-Commit:$E1"

  # Upstream reverts the banner; we absorb that properly.
  external_commit pkg/app.go "l1-l2-l3" "revert: the banner" >/dev/null
  absorb_external

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value diverged)" = "false" ]
  # Nothing replayed: both sync commits are recognised as OSS-originated.
  [ "$(output_value exported-count)" = "0" ]
  # The revert stands; the banner was not resurrected.
  [ "$(oss_file pkg/app.go)" = "l1-l2-l3" ]
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]
}

@test "our own export is recognised from a Monorepo-Commit only git parses" {
  # The guard asks "did we create this OSS commit", and the resume point comes from
  # the same reading. If a Monorepo-Commit written in git's laxer form is invisible
  # to it, our own export looks like an unabsorbed external commit. The content it
  # carried has to be superseded for this to bite, otherwise external_is_benign
  # rescues it and the test proves nothing.
  C1=$(company_commit pkg/app.go "v1" "feat: company v1")
  bash "$EXPORT"
  ours=$(oss_tip)
  # Rewrite that OSS commit's trailer into a form only git's parser reads.
  (
    cd "$ROOT"
    git clone -q "$OSS_REMOTE" relabel
    cd relabel
    git commit -q --amend -m "feat: company v1

Monorepo-Commit:$(echo "$C1" | tr 'a-f' 'A-F')"
    git push -q --force origin main
  )
  [ "$(oss_tip)" != "$ours" ]
  # Supersede v1, so the exported content is no longer in the subtree.
  company_commit pkg/app.go "v2" "feat: company v2" >/dev/null

  run bash "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value diverged)" = "false" ]
  [[ "$output" != *"not yet absorbed"* ]]
  [ "$(oss_file pkg/app.go)" = "v2" ]
  [ "$(git -C "$OSS_REMOTE" rev-parse 'main^{tree}')" = "$(git -C "$MONO" rev-parse "HEAD:$PFX")" ]
}

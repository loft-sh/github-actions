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

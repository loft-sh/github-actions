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

  SEED_OSS_COMMIT="$O0" run bash "$IMPORT"
  [ "$status" -eq 0 ]
  [ "$(output_value replayed-count)" = "1" ]
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

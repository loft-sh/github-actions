#!/usr/bin/env bats
# Tests for run.sh
#
# Uses real temporary git repos: a "monorepo" (pro code at root + an OSS subtree
# under the prefix) and two bare "legacy" remotes (an OSS repo and a pro repo,
# each with a v0.35 branch in the old root layout). The re-root, path-partition
# and 3-way apply logic is exercised end to end; pushes go to local bare repos,
# not the network. CREATE_PR is left unset so the git surgery is tested without
# gh.

setup() {
  ROOT=$(mktemp -d)
  export ROOT
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
  export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always

  SCRIPT="$BATS_TEST_DIRNAME/../run.sh"
  export PFX="staging/github.com/loft-sh/vcluster"

  # Bare legacy OSS remote: OSS content at root, on a v0.35 branch.
  export OSS_REMOTE="$ROOT/oss.git"
  git init -q --bare "$OSS_REMOTE"
  git init -q "$ROOT/oss-seed"
  (
    cd "$ROOT/oss-seed"
    git checkout -q -b v0.35
    printf 'line1\nline2\nline3\n' > app.go
    git add -A && git commit -qm "oss legacy: seed"
    git push -q "$OSS_REMOTE" v0.35
  )

  # Bare legacy pro remote: pro content + go.mod at root, on a v0.35 branch.
  export PRO_REMOTE="$ROOT/pro.git"
  git init -q --bare "$PRO_REMOTE"
  git init -q "$ROOT/pro-seed"
  (
    cd "$ROOT/pro-seed"
    git checkout -q -b v0.35
    printf 'package main\n' > main.go
    printf 'module github.com/loft-sh/vcluster-pro\n\nrequire github.com/loft-sh/vcluster v0.35.1\n' > go.mod
    git add -A && git commit -qm "pro legacy: seed"
    git push -q "$PRO_REMOTE" v0.35
  )

  # Monorepo: OSS under the prefix (same base content as the OSS remote), pro at
  # root (same base content as the pro remote).
  export MONO="$ROOT/mono"
  git init -q "$MONO"
  cd "$MONO"
  git checkout -q -b main
  mkdir -p "$PFX"
  printf 'line1\nline2\nline3\n' > "$PFX/app.go"
  printf 'package main\n' > main.go
  printf 'module github.com/loft-sh/vcluster-pro\n\nrequire github.com/loft-sh/vcluster v0.36.0\n' > go.mod
  git add -A && git commit -qm "monorepo: seed"

  export SUBTREE_PREFIX="$PFX"
  export TARGET_BRANCH=v0.35
  export WORKDIR="$ROOT/work"
  export GITHUB_OUTPUT="$ROOT/output"
  : > "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$ROOT"
}

# Install a fake `gh` on PATH so the CREATE_PR=true paths can be exercised
# hermetically (no network). Controlled by env:
#   GH_PRLIST=empty|exists|fail  -- what `gh pr list` returns (default empty)
#   GH_CREATE_LOG=<file>         -- `gh pr create` appends its argv here (one/line)
install_fake_gh() {
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = pr ] && [ "$2" = list ]; then
  printf '%s\n' "$@" >> "${GH_PRLIST_LOG:-/dev/null}"
  case "${GH_PRLIST:-empty}" in
    fail) exit 3 ;;
    exists) echo 42 ;;
    *) : ;;
  esac
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = create ]; then
  printf '%s\n' "$@" >> "${GH_CREATE_LOG:?}"
  echo "https://github.com/x/y/pull/99"
  exit 0
fi
# `gh pr view <n> --json url --jq .url` -- surface the existing PR's URL.
if [ "$1" = pr ] && [ "$2" = view ]; then
  echo "https://github.com/x/y/pull/$3"
  exit 0
fi
if [ "$1" = api ]; then   # `gh api user --jq .login`
  echo "loft-bot"
  exit 0
fi
exit 0
STUB
  chmod +x "$ROOT/bin/gh"
  export PATH="$ROOT/bin:$PATH"
  export CREATE_PR=true GH_TOKEN=dummy OSS_REPO=loft-sh/vcluster PRO_REPO=loft-sh/vcluster-pro
  export GH_CREATE_LOG="$ROOT/gh-create.log"; : > "$GH_CREATE_LOG"
  export GH_PRLIST_LOG="$ROOT/gh-prlist.log"; : > "$GH_PRLIST_LOG"
}

output_value() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-; }

# comment-body is emitted with the GITHUB_OUTPUT heredoc form (it's multi-line),
# so output_value can't read it -- extract the block between the delimiters.
comment_body() {
  awk '/^comment-body<<__BACKPORT_BODY_EOF__$/{f=1;next} /^__BACKPORT_BODY_EOF__$/{f=0} f' "$GITHUB_OUTPUT"
}

# Content of <path> on <branch> in a bare remote.
remote_file() { git -C "$1" show "$2:$3"; }
# All tracked paths on <branch> in a bare remote.
remote_paths() { git -C "$1" ls-tree -r --name-only "$2"; }

short() { git -C "$MONO" rev-parse --short HEAD; }

# --- classification --------------------------------------------------------

@test "pro-only commit applies onto the pro legacy branch (no OSS push)" {
  cd "$MONO"
  printf 'package main // v2\n' > main.go
  git commit -qam "pro: change"
  local br="backport/v0.35/$(short)"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "pro-only" ]
  [ "$(output_value pro-pushed)" = "true" ]
  [ "$(output_value oss-pushed)" = "false" ]
  [ "$(output_value pro-conflicts)" = "false" ]
  # Pro change landed at root on the pro remote, and no staging/ tree appeared.
  run bash -c "git -C '$PRO_REMOTE' show '$br:main.go' | grep -q 'v2'"
  [ "$status" -eq 0 ]
  run bash -c "git -C '$PRO_REMOTE' ls-tree -r --name-only '$br' | grep staging"
  [ "$status" -ne 0 ]
}

@test "re-running the same commit is idempotent (force-push, existing branch)" {
  cd "$MONO"
  printf 'line1\nCHANGED\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pushed)" = "true" ]

  # Second run targets the same deterministic branch already on the remote;
  # the force-push must not fail on a non-fast-forward.
  : > "$GITHUB_OUTPUT"
  rm -rf "$WORKDIR"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pushed)" = "true" ]
}

# --- oss-only: re-root -----------------------------------------------------

@test "oss-only commit re-roots and pushes onto the OSS legacy branch" {
  cd "$MONO"
  printf 'line1\nCHANGED\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"
  local br="backport/v0.35/$(short)"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "oss-only" ]
  [ "$(output_value oss-pushed)" = "true" ]
  [ "$(output_value oss-conflicts)" = "false" ]
  [ "$(output_value backport-branch)" = "$br" ]
  # Change landed at the OSS root path (prefix stripped), not under staging/.
  [ "$(remote_file "$OSS_REMOTE" "$br" app.go)" = "$(printf 'line1\nCHANGED\nline3')" ]
  run bash -c "git -C '$OSS_REMOTE' ls-tree -r --name-only '$br' | grep staging"
  [ "$status" -ne 0 ]
}

@test "multi-commit PR (same file): PR-head diff captures every commit" {
  cd "$MONO"
  # PR head: two commits editing the SAME OSS file (the shape the old file-name
  # guard missed). Then a squash-style merge commit on main carrying both changes.
  git checkout -q -b prhead
  printf 'line1-c1\nline2\nline3\n' > "$PFX/app.go"; git commit -qam c1
  printf 'line1-c1\nline2\nline3-c2\n' > "$PFX/app.go"; git commit -qam c2
  local prhead; prhead="$(git rev-parse HEAD)"
  git checkout -q main
  printf 'line1-c1\nline2\nline3-c2\n' > "$PFX/app.go"; git commit -qam "squash (#1)"
  local mergec; mergec="$(git rev-parse HEAD)"
  local br="backport/v0.35/$(git rev-parse --short "$mergec")"

  # Expose the PR head as refs/pull/1/head on an origin the action can fetch.
  local origin="$ROOT/origin.git"
  git init -q --bare "$origin"
  git push -q "$origin" main
  git push -q "$origin" "$prhead:refs/pull/1/head"
  git remote add origin "$origin"

  COMMIT="$mergec" PR_NUMBER=1 GH_TOKEN=dummy run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "oss-only" ]
  [ "$(output_value oss-pushed)" = "true" ]
  # BOTH commits' edits land (not just the last one).
  run bash -c "git -C '$OSS_REMOTE' show '$br:app.go' | grep -q 'line1-c1'"
  [ "$status" -eq 0 ]
  run bash -c "git -C '$OSS_REMOTE' show '$br:app.go' | grep -q 'line3-c2'"
  [ "$status" -eq 0 ]
}

@test "merge-commit PR: first-parent merge base captures the whole PR" {
  cd "$MONO"
  git checkout -q -b prheadmc
  printf 'line1-c1\nline2\nline3\n' > "$PFX/app.go"; git commit -qam c1
  printf 'line1-c1\nline2\nline3-c2\n' > "$PFX/app.go"; git commit -qam c2
  local prhead; prhead="$(git rev-parse HEAD)"
  git checkout -q main
  # base drift on a different path so the --no-ff merge is clean
  printf 'x\n' > basefile.txt; git add -A; git commit -qm "base drift"
  git merge -q --no-ff -m "merge PR (#2)" "$prhead"
  local mergec; mergec="$(git rev-parse HEAD)"
  local br="backport/v0.35/$(git rev-parse --short "$mergec")"

  local origin="$ROOT/origin2.git"
  git init -q --bare "$origin"
  git push -q "$origin" main
  git push -q "$origin" "$prhead:refs/pull/2/head"
  git remote add origin "$origin"

  # merge-base(mergec, prhead) would be prhead (2nd parent) -> empty diff; the
  # ^1 anchor uses the base side, so both commits' edits must land.
  COMMIT="$mergec" PR_NUMBER=2 GH_TOKEN=dummy run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "oss-only" ]
  run bash -c "git -C '$OSS_REMOTE' show '$br:app.go' | grep -q 'line1-c1'"
  [ "$status" -eq 0 ]
  run bash -c "git -C '$OSS_REMOTE' show '$br:app.go' | grep -q 'line3-c2'"
  [ "$status" -eq 0 ]
}

@test "oss-only commit with a non-ASCII path classifies correctly (quotePath)" {
  cd "$MONO"
  printf 'x\n' > "$PFX/café.go"
  git add -A && git commit -qm "oss: non-ascii filename"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # Without core.quotePath=false, git would print "staging/.../caf\303\251.go"
  # (leading quote) and the prefix match would miss -> misrouted to pro-only.
  [ "$(output_value route)" = "oss-only" ]
  [ "$(output_value oss-pushed)" = "true" ]
}

@test "sibling module sharing the prefix string does not leak into the OSS patch" {
  cd "$MONO"
  # One commit: modify the real subtree file AND add a NEW file in a sibling dir
  # whose name starts with the prefix string but is a different component.
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  mkdir -p "${PFX}-pro"
  printf 'pkg sib\n' > "${PFX}-pro/sib.go"
  git add -A && git commit -qm "oss + sibling"
  local br="backport/v0.35/$(short)"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "mixed" ]
  # OSS patch carries ONLY the real subtree file, re-rooted to app.go -- no
  # '-pro/sib.go' garbage path leaked in by byte-prefix matching.
  run bash -c "git -C '$OSS_REMOTE' show '$br:app.go' | grep -q OSS"
  [ "$status" -eq 0 ]
  run bash -c "git -C '$OSS_REMOTE' ls-tree -r --name-only '$br' | grep -- '-pro'"
  [ "$status" -ne 0 ]
}

@test "binary file change is carried (needs --binary)" {
  cd "$MONO"
  printf '\x00\x01\x02\x03BIN\n' > "$PFX/blob.bin"
  git add -A && git commit -qm "oss: add binary"
  local br="backport/v0.35/$(short)"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "oss-only" ]
  [ "$(output_value oss-pushed)" = "true" ]
  [ "$(output_value oss-conflicts)" = "false" ]
  # The binary landed on the OSS branch (a plain diff would emit an unappliable
  # "Binary files differ" placeholder and fail the apply).
  run bash -c "git -C '$OSS_REMOTE' show '$br:blob.bin' | tr -d '\0' | grep -q BIN"
  [ "$status" -eq 0 ]
}

@test "apply that stages nothing due to a failure fails loudly (not 'nothing to commit')" {
  # Legacy branch deleted a file the patch modifies -> git apply --3way fails
  # with "does not exist in index" and stages nothing. Must error clearly, not
  # crash with an opaque "nothing to commit".
  git clone -q --branch v0.35 --single-branch "$OSS_REMOTE" "$ROOT/ossdel"
  (
    cd "$ROOT/ossdel"
    git rm -q app.go && git commit -qm "drop app.go" && git push -q origin v0.35
  )
  cd "$MONO"
  printf 'line1\nMOD\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: modify app.go"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot 3-way apply"* ]]
  [ "$(output_value oss-pushed)" = "false" ]
}

@test "re-backport of an already-applied DELETION skips (not a loud fail)" {
  # Legacy branch already lacks app.go; the backport also deletes app.go. A
  # forward --3way of a delete-of-absent-file fails, but the reverse-check proves
  # the deletion is already applied -> skip, don't hard-fail.
  git clone -q --branch v0.35 --single-branch "$OSS_REMOTE" "$ROOT/ossdel2"
  (
    cd "$ROOT/ossdel2"
    git rm -q app.go && git commit -qm "already deleted app.go" && git push -q origin v0.35
  )
  cd "$MONO"
  git rm -q "$PFX/app.go"
  git commit -qm "oss: delete app.go"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pushed)" = "false" ]
  # Nothing applied -> conflicts must stay false (no phantom conflict output).
  [ "$(output_value oss-conflicts)" = "false" ]
  [[ "$output" == *"no changes to apply"* ]]
}

@test "no-op apply (change already on the legacy branch) skips instead of erroring" {
  # Make the OSS legacy branch already carry the exact change we'll backport.
  git clone -q --branch v0.35 --single-branch "$OSS_REMOTE" "$ROOT/ossdup"
  (
    cd "$ROOT/ossdup"
    printf 'line1\nALREADY\nline3\n' > app.go
    git commit -qam "already applied" && git push -q origin v0.35
  )
  cd "$MONO"
  printf 'line1\nALREADY\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: same change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pushed)" = "false" ]
  [[ "$output" == *"no changes to apply"* ]]
}

@test "oss-only commit onto a divergent branch commits conflict markers" {
  # Make the OSS legacy branch diverge on the same line.
  git clone -q --branch v0.35 --single-branch "$OSS_REMOTE" "$ROOT/ossdiv"
  (
    cd "$ROOT/ossdiv"
    printf 'line1\nLEGACY-DIVERGENT\nline3\n' > app.go
    git commit -qam "oss legacy: divergent" && git push -q origin v0.35
  )

  cd "$MONO"
  printf 'line1\nCHANGED\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"
  local br="backport/v0.35/$(short)"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-conflicts)" = "true" ]
  [ "$(output_value oss-pushed)" = "true" ]
  run bash -c "git -C '$OSS_REMOTE' show '$br:app.go' | grep -q '<<<<<<<'"
  [ "$status" -eq 0 ]
}

@test "pro-only commit onto a divergent pro branch commits conflict markers" {
  # Symmetric to the OSS-divergent case, exercising the pro half of backport_side:
  # a bug that left `conflicts` always false on the pro side (or mis-keyed the
  # `emit "${side}-conflicts"`) would open a conflicted pro PR as non-draft and
  # emit pro-conflicts=false. Diverge the pro legacy branch on the same line the
  # commit touches so the 3-way apply must produce markers.
  git clone -q --branch v0.35 --single-branch "$PRO_REMOTE" "$ROOT/prodiv"
  (
    cd "$ROOT/prodiv"
    printf 'package main // LEGACY-DIVERGENT\n' > main.go
    git commit -qam "pro legacy: divergent" && git push -q origin v0.35
  )

  cd "$MONO"
  printf 'package main // v2\n' > main.go
  git commit -qam "pro: change"
  local br="backport/v0.35/$(short)"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "pro-only" ]
  [ "$(output_value pro-conflicts)" = "true" ]
  [ "$(output_value pro-pushed)" = "true" ]
  [ "$(output_value oss-pushed)" = "false" ]
  run bash -c "git -C '$PRO_REMOTE' show '$br:main.go' | grep -q '<<<<<<<'"
  [ "$status" -eq 0 ]
}

# --- mixed: split ----------------------------------------------------------

@test "mixed commit opens both halves; pro half keeps go.mod and no staging tree" {
  cd "$MONO"
  printf 'line1\nOSS-CHANGE\nline3\n' > "$PFX/app.go"
  printf 'package main // pro change\n' > main.go
  printf 'module github.com/loft-sh/vcluster-pro\n\nrequire github.com/loft-sh/vcluster v0.36.0\nrequire example.com/dep v1.2.3\n' > go.mod
  git commit -qam "mixed: oss + pro + go.mod"
  local br="backport/v0.35/$(short)"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "mixed" ]
  [ "$(output_value oss-pushed)" = "true" ]
  [ "$(output_value pro-pushed)" = "true" ]

  # OSS half: re-rooted OSS change only, no pro files.
  [ "$(remote_file "$OSS_REMOTE" "$br" app.go)" = "$(printf 'line1\nOSS-CHANGE\nline3')" ]
  run bash -c "git -C '$OSS_REMOTE' ls-tree -r --name-only '$br' | grep -E 'main.go|go.mod|staging'"
  [ "$status" -ne 0 ]

  # Pro half: pro change + go.mod dep bump carried, and NO staging/ tree created.
  run bash -c "git -C '$PRO_REMOTE' show '$br:main.go' | grep -q 'pro change'"
  [ "$status" -eq 0 ]
  run bash -c "git -C '$PRO_REMOTE' show '$br:go.mod' | grep -q 'example.com/dep'"
  [ "$status" -eq 0 ]
  run bash -c "git -C '$PRO_REMOTE' ls-tree -r --name-only '$br' | grep staging"
  [ "$status" -ne 0 ]
}

# --- CREATE_PR=true paths (fake gh, hermetic) ------------------------------

@test "create-pr: a clean backport opens a non-draft PR" {
  install_fake_gh                       # GH_PRLIST defaults to empty -> proceed
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pushed)" = "true" ]
  grep -q '^create$' "$GH_CREATE_LOG"
  run grep -Fxq -- --draft "$GH_CREATE_LOG"
  [ "$status" -ne 0 ]                   # clean PR is NOT a draft
}

@test "create-pr: an existing open PR is detected and the side is skipped" {
  install_fake_gh
  export GH_PRLIST=exists
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pushed)" = "false" ]
  [[ "$output" == *"already open"* ]]
  [ ! -s "$GH_CREATE_LOG" ]             # no PR created
}

@test "create-pr: a failed open-PR query fails safe (skip, don't clobber)" {
  install_fake_gh
  export GH_PRLIST=fail
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pushed)" = "false" ]
  [[ "$output" == *"could not query open PRs"* ]]
  [ ! -s "$GH_CREATE_LOG" ]
}

@test "create-pr: a mixed commit opens two PRs, and the open-PR query is well-formed" {
  install_fake_gh
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  printf 'package main // pro\n' > main.go
  git commit -qam "mixed: oss + pro"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value route)" = "mixed" ]
  # One create per side (oss + pro), neither a draft (clean apply).
  [ "$(grep -c '^create$' "$GH_CREATE_LOG")" -eq 2 ]
  run grep -Fxq -- --draft "$GH_CREATE_LOG"
  [ "$status" -ne 0 ]
  # Each half targeted its OWN repo. A presence-only check (both slugs appear)
  # would also pass on a slug SWAP -- OSS half -> vcluster-pro, pro half ->
  # vcluster -- since each slug still logs exactly once. The OSS half is always
  # processed before the pro half, so pin the pairing by ORDER: the OSS slug's
  # --repo line must precede the pro slug's. The fake gh logs every argv token on
  # its own line, so each slug is a whole-line match (-x), and vcluster-pro won't
  # match the vcluster line.
  local oss_ln pro_ln
  oss_ln="$(grep -nxF -- 'loft-sh/vcluster' "$GH_CREATE_LOG" | head -n1 | cut -d: -f1)"
  pro_ln="$(grep -nxF -- 'loft-sh/vcluster-pro' "$GH_CREATE_LOG" | head -n1 | cut -d: -f1)"
  [ -n "$oss_ln" ] && [ -n "$pro_ln" ]
  [ "$oss_ln" -lt "$pro_ln" ]
  # The existing-PR guard queried open PRs for the deterministic head/base --
  # a regression to that filter would skip forever or clobber.
  grep -Fxq -- --state "$GH_PRLIST_LOG"
  grep -Fxq -- open "$GH_PRLIST_LOG"
  grep -q "backport/v0.35/" "$GH_PRLIST_LOG"
}

@test "create-pr: a conflicted backport opens a DRAFT PR" {
  install_fake_gh
  # Diverge the OSS legacy branch so the apply conflicts.
  git clone -q --branch v0.35 --single-branch "$OSS_REMOTE" "$ROOT/ossdiv"
  (
    cd "$ROOT/ossdiv"
    printf 'line1\nLEGACY\nline3\n' > app.go
    git commit -qam "oss legacy: divergent" && git push -q origin v0.35
  )
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-conflicts)" = "true" ]
  [ "$(output_value oss-pushed)" = "true" ]
  grep -Fxq -- --draft "$GH_CREATE_LOG"  # conflicted PR opened as draft
}

# --- summary comment (backport PR links back onto the source PR) -----------

@test "comment: a clean backport emits the PR url and a success summary comment" {
  install_fake_gh
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pr-url)" = "https://github.com/x/y/pull/99" ]
  [ "$(output_value pro-pr-url)" = "" ]

  run comment_body
  [[ "$output" == *':white_check_mark: Backported to `v0.35`'* ]]
  [[ "$output" == *'- **oss:** https://github.com/x/y/pull/99'* ]]
  # Clean apply -> no conflict warning in the body.
  [[ "$output" != *':warning:'* ]]
}

@test "comment: a conflicted backport flags the draft in the summary comment" {
  install_fake_gh
  git clone -q --branch v0.35 --single-branch "$OSS_REMOTE" "$ROOT/ossdiv"
  (
    cd "$ROOT/ossdiv"
    printf 'line1\nLEGACY\nline3\n' > app.go
    git commit -qam "oss legacy: divergent" && git push -q origin v0.35
  )
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run comment_body
  [[ "$output" == *':warning: Backported to `v0.35`'* ]]
  [[ "$output" == *'opened as a draft'* ]]
}

@test "comment: a mixed backport lists both the pro and oss PRs" {
  install_fake_gh
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  printf 'package main // pro\n' > main.go
  git commit -qam "mixed: oss + pro"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pr-url)" = "https://github.com/x/y/pull/99" ]
  [ "$(output_value pro-pr-url)" = "https://github.com/x/y/pull/99" ]

  run comment_body
  [[ "$output" == *'- **pro:** https://github.com/x/y/pull/99'* ]]
  [[ "$output" == *'- **oss:** https://github.com/x/y/pull/99'* ]]
}

@test "comment: an already-open PR still appears in the summary comment" {
  install_fake_gh
  export GH_PRLIST=exists          # skip create; the existing PR is #42
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_CREATE_LOG" ]                                   # nothing created
  [ "$(output_value oss-pr-url)" = "https://github.com/x/y/pull/42" ]

  run comment_body
  [[ "$output" == *'- **oss:** https://github.com/x/y/pull/42'* ]]
}

@test "comment: nothing opened or found -> empty comment body" {
  install_fake_gh
  export GH_PRLIST=fail            # query fails -> side skipped, no PR, no url
  cd "$MONO"
  printf 'line1\nOSS\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(comment_body)" ]
}

# --- guards ----------------------------------------------------------------

@test "missing required env fails" {
  cd "$MONO"
  printf 'line1\nX\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"
  unset SUBTREE_PREFIX
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "a commit that changes no files fails loudly" {
  # An empty commit has no diff under either the subtree prefix or the pro root,
  # so classification leaves oss=pro=false and the guard must error rather than
  # push an empty backport branch. Guards against a regression that skipped the
  # check and silently continued past an empty diff.
  cd "$MONO"
  git commit -q --allow-empty -m "empty: no file changes"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changes no files"* ]]
  [ "$(output_value oss-pushed)" = "false" ]
  [ "$(output_value pro-pushed)" = "false" ]
}

# --- commit identity -------------------------------------------------------

@test "commits under the bot identity when no ambient git identity is set" {
  # Regression: the target checkout is a fresh clone that carries no
  # user.name/user.email, so an unqualified `git commit` died with
  # "empty ident name" in real CI. The rest of the suite masks this because
  # setup() exports GIT_{AUTHOR,COMMITTER}_* -- here we strip them (and rely on
  # the user-less GIT_CONFIG_GLOBAL) to reproduce the CI environment, and assert
  # the commit still lands under the github-actions[bot] identity.
  cd "$MONO"
  printf 'line1\nCHANGED\nline3\n' > "$PFX/app.go"
  git commit -qam "oss: change"
  local br="backport/v0.35/$(short)"

  run env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
          -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
          bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(output_value oss-pushed)" = "true" ]

  # Both author and committer must be the bot -- proving the identity came from
  # run.sh's inline -c flags, not leftover ambient config.
  [ "$(git -C "$OSS_REMOTE" show -s --format='%an' "$br")" = "github-actions[bot]" ]
  [ "$(git -C "$OSS_REMOTE" show -s --format='%cn' "$br")" = "github-actions[bot]" ]
  [ "$(git -C "$OSS_REMOTE" show -s --format='%ae' "$br")" = "41898282+github-actions[bot]@users.noreply.github.com" ]
}

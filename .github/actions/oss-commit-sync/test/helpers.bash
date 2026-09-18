# Shared fixture for export.bats / import.bats.
#
# Builds a "mono" monorepo (subtree prefix + pro-only file) and a bare "oss"
# remote whose seed commit carries the Monorepo-Commit trailer anchor, i.e.
# the state right after a completed migration. All pushes go to the local
# bare repo, never the network.

setup_fixture() {
  ROOT=$(mktemp -d)
  export ROOT
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@company.example
  export GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@company.example
  export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always
  # CI runners have no GECOS name, so git cannot invent an ident there; make
  # local runs equally strict so missing-ident regressions bite everywhere.
  git config --file "$GIT_CONFIG_GLOBAL" user.useConfigOnly true

  EXPORT="$BATS_TEST_DIRNAME/../export.sh"
  IMPORT="$BATS_TEST_DIRNAME/../import.sh"
  PFX="staging/github.com/loft-sh/vcluster"

  # Monorepo seed.
  MONO="$ROOT/mono"
  export MONO
  git init -q "$MONO"
  cd "$MONO"
  git checkout -q -b main
  mkdir -p "$PFX/pkg"
  printf 'l1\nl2\nl3\n' > "$PFX/pkg/app.go"
  echo "pro-only" > pro.txt
  git add . && git commit -qm "seed monorepo"
  M0=$(git rev-parse HEAD)
  export M0

  # Bare OSS remote: same content at the root, trailer-anchored to M0.
  OSS_REMOTE="$ROOT/oss.git"
  export OSS_REMOTE
  git init -q --bare "$OSS_REMOTE"
  git init -q "$ROOT/ossseed"
  (
    cd "$ROOT/ossseed"
    git checkout -q -b main
    mkdir -p pkg
    printf 'l1\nl2\nl3\n' > pkg/app.go
    git add . && git commit -qm "seed oss

Monorepo-Commit: $M0"
    git push -q "$OSS_REMOTE" main
  )
  O0=$(git -C "$OSS_REMOTE" rev-parse main)
  export O0

  # Migration state: monorepo main records that OSS is pulled up to O0
  # (the doc's "seed the from-oss marker" step).
  cd "$MONO"
  git commit -q --allow-empty -m "chore: seed sync state

Oss-Commit: $O0"
  export SUBTREE_PREFIX="$PFX"
  export BRANCH=main
  export GITHUB_OUTPUT="$ROOT/output"
  : > "$GITHUB_OUTPUT"
}

teardown_fixture() {
  rm -rf "$ROOT"
}

output_value() {
  grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-
}

# company_commit <file-under-prefix> <content> <subject>
company_commit() {
  (
    cd "$MONO"
    mkdir -p "$(dirname "$PFX/$1")"
    printf '%s\n' "$2" > "$PFX/$1"
    git add . && git commit -qm "$3"
  )
  git -C "$MONO" rev-parse HEAD
}

# external_commit <file> <content> <subject> — a contributor PR merged on OSS.
external_commit() {
  local clone="$ROOT/ext-$RANDOM"
  git clone -q "$OSS_REMOTE" "$clone"
  (
    cd "$clone"
    git checkout -q main
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
    git add .
    GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL=alice@contributor.example \
      git commit -qm "$3"
    git push -q origin main
  )
  git -C "$OSS_REMOTE" rev-parse main
}

# squash_merge_pr_branch <commit-message> — simulate GitHub's "Squash and merge"
# button on the sync PR: one commit on the base branch carrying the PR branch's
# combined diff and a caller-provided message. Callers pass the message shape
# they are testing, notably GitHub's habit of appending a Co-authored-by
# paragraph after any trailer the branch already wrote.
squash_merge_pr_branch() {
  local msg="$1"
  (
    cd "$MONO"
    git switch -q main
    git merge --squash -q "automation/sync-from-oss-main"
    git commit -qm "$msg"
  )
}

# absorb_external — run the real import + simulate a rebase-merge (FF) of the
# sync PR, i.e. the state after a from-oss PR landed on main.
absorb_external() {
  (
    cd "$MONO"
    bash "$IMPORT" >/dev/null
    git switch -q main
    git merge -q --ff-only "automation/sync-from-oss-main"
  )
}

oss_log_subjects() {
  git -C "$OSS_REMOTE" log --format=%s main
}

oss_file() {
  git -C "$OSS_REMOTE" show "main:$1"
}

oss_tip() {
  git -C "$OSS_REMOTE" rev-parse main
}

# write_binary <path> <seed>
# A file git treats as binary (the NUL in the header is inside the first 8000
# bytes, which is what git looks at), with enough body that it diffs as a real
# GIT binary patch rather than as text.
#
# Every byte derives from <seed>, so the same seed always rebuilds the same
# file and a failing run's fixture can be reproduced from the log. The chain is
# hashed rather than repeated because git stores blobs zlib-compressed and a
# repetitive body can pack down far enough that the two revisions of the file
# produce a delta instead of the literal this suite is about.
write_binary() {
  local seed="$2" h i
  mkdir -p "$(dirname "$1")"
  {
    printf 'PNG\000\r\n\032\n'
    h="$seed"
    for i in $(seq 1 32); do
      # git, not sha1sum/shasum: git is already required here, and the two
      # checksum tools are not both present on every platform this runs on.
      h="$(printf '%s' "$h" | git hash-object -t blob --stdin)"
      printf '%s' "$h"
    done
    printf '\000seed=%s\n' "$seed"
  } > "$1"
}

# external_binary_commit <text-file> <bin-file> <seed> <subject>
# An OSS commit whose LAST file in diff order is binary: that is where the
# GIT binary patch terminator lands on the final byte of the diff.
external_binary_commit() {
  local clone="$ROOT/ext-$RANDOM"
  git clone -q "$OSS_REMOTE" "$clone"
  (
    cd "$clone"
    git checkout -q main
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "touched by $3" > "$1"
    write_binary "$2" "$3"
    git add .
    GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL=alice@contributor.example \
      git commit -qm "$4"
    git push -q origin main
  )
  git -C "$OSS_REMOTE" rev-parse main
}

# external_binary_only_commit <bin-file> <seed> <subject>
# An OSS commit whose ONLY file is binary, i.e. the binary is both first and
# last in diff order. The terminator the export/import used to strip is still
# the diff's final byte, but there is no earlier file left to apply, so a
# stripped diff loses the whole commit rather than part of it.
external_binary_only_commit() {
  local clone="$ROOT/ext-$RANDOM"
  git clone -q "$OSS_REMOTE" "$clone"
  (
    cd "$clone"
    git checkout -q main
    write_binary "$1" "$2"
    git add .
    GIT_AUTHOR_NAME=alice GIT_AUTHOR_EMAIL=alice@contributor.example \
      git commit -qm "$3"
    git push -q origin main
  )
  git -C "$OSS_REMOTE" rev-parse main
}

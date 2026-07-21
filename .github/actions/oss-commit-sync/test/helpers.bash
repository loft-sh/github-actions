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

#!/usr/bin/env bats
# Unit tests for lib.sh trailer helpers, incl. the large-history SIGPIPE
# regression: newest_trailer_entry must not close the git-log pipe early
# (exit 141 under pipefail on big repos, build-dependent).

setup() {
  ROOT=$(mktemp -d); export ROOT
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_CONFIG_GLOBAL="$ROOT/gc"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # shellcheck disable=SC1090
  source "$BATS_TEST_DIRNAME/../lib.sh"
  git init -q "$ROOT/r"; cd "$ROOT/r"
}
teardown() { rm -rf "$ROOT"; }

@test "newest_trailer_entry returns the newest match" {
  git commit -q --allow-empty -m "old

Monorepo-Commit: oldsha"
  git commit -q --allow-empty -m "new

Monorepo-Commit: newsha"
  run newest_trailer_entry HEAD Monorepo-Commit
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | awk '{print $2}')" = "newsha" ]
}

@test "newest_trailer_entry is empty when no trailer present" {
  git commit -q --allow-empty -m "no trailer here"
  run newest_trailer_entry HEAD Monorepo-Commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "newest_trailer_entry survives a large history under pipefail (SIGPIPE regression)" {
  # Fabricate ~2500 commits cheaply; newest carries the trailer so a naive
  # early-exit consumer would close the pipe after line 1 while git streams
  # the rest (>64KB) -> SIGPIPE -> 141 under pipefail.
  et=$(git mktree </dev/null)
  prev=$(git commit-tree "$et" -m root)
  for i in $(seq 1 2500); do prev=$(git commit-tree "$et" -p "$prev" -m "c$i"); done
  head=$(git commit-tree "$et" -p "$prev" -m "newest

Monorepo-Commit: TARGETSHA")
  git update-ref refs/heads/main "$head"
  set -o pipefail
  run newest_trailer_entry main Monorepo-Commit
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | awk '{print $2}')" = "TARGETSHA" ]
}

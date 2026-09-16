#!/usr/bin/env bats
# The staleness check exists because a failed export is invisible. Its own
# failure modes therefore matter more than usual: every test here asserts both
# what it reported AND that it exited 0, because a check that dies is a check
# that is silent, which is the bug it was written to fix.

setup() {
  CHECK="$BATS_TEST_DIRNAME/../src/oss-mirror-staleness.sh"
  ROOT=$(mktemp -d)
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@company.example
  export GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@company.example
  export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # Fetching from the bare fixture repo goes over file://, which recent git
  # refuses by default.
  git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always
  git config --file "$GIT_CONFIG_GLOBAL" user.useConfigOnly true

  PFX="staging/github.com/loft-sh/vcluster"
  MONO="$ROOT/mono"
  git init -q "$MONO"
  cd "$MONO"
  git checkout -q -b main
  mkdir -p "$PFX/pkg"
  echo "seed" >"$PFX/pkg/app.go"
  echo "pro-only" >pro.txt
  git add .
  # Dated in the past so ages are deterministic when a walk reaches the seed.
  SEED_DATE="$(date -u -d '200 hours ago' +%s) +0000"
  GIT_AUTHOR_DATE="$SEED_DATE" GIT_COMMITTER_DATE="$SEED_DATE" \
    git commit -qm "seed monorepo"
  M0=$(git rev-parse HEAD)

  OSS="$ROOT/oss.git"
  git init -q --bare "$OSS"
  git init -q "$ROOT/ossseed"
  (
    cd "$ROOT/ossseed"
    git checkout -q -b main
    mkdir -p pkg
    echo "seed" >pkg/app.go
    git add . && git commit -qm "seed oss

Monorepo-Commit: $M0"
    git push -q "$OSS" main
  )

  cd "$MONO"
  export SUBTREE_PREFIX="$PFX"
  export OSS_REMOTE="$OSS"
  export OSS_REPO="loft-sh/vcluster"
  export BRANCH=main
  export GITHUB_OUTPUT="$ROOT/output"
  export GITHUB_STEP_SUMMARY="$ROOT/summary.md"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
}

teardown() {
  rm -rf "$ROOT"
}

out() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-; }

# mono_commit <subject> [hours-ago]: a monorepo commit touching the subtree.
mono_commit() {
  local subject="$1" hours="${2:-0}" when
  when=$(date -u -d "${hours} hours ago" +%s)
  (
    cd "$MONO"
    echo "$subject" >>"$PFX/pkg/app.go"
    git add .
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
      git commit -qm "$subject"
  )
  git -C "$MONO" rev-parse HEAD
}

# oss_mirror_content <message>: push the exact subtree content to OSS, i.e. what
# a completed export leaves behind.
oss_mirror_content() {
  local clone="$ROOT/ossm-$RANDOM"
  git clone -q "$OSS" "$clone"
  (
    cd "$clone"
    git checkout -q main
    find . -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
    cp -r "$MONO/$PFX/." .
    git add -A
    git commit -qm "$1"
    git push -q origin main
  )
}

# oss_record <message>: an OSS commit carrying whatever message is given, so
# tests can shape the trailer exactly.
oss_record() {
  local clone="$ROOT/ossw-$RANDOM"
  git clone -q "$OSS" "$clone"
  (
    cd "$clone"
    git checkout -q main
    echo "$RANDOM" >>pkg/app.go
    git add .
    git commit -qm "$1"
    git push -q origin main
  )
}

@test "a mirror carrying every subtree commit is in sync" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "false" ]
  [ "$(out degraded)" = "false" ]
  [ "$(out backlog-count)" = "0" ]
  [ "$(out frontier)" = "$m1" ]
}

@test "commits the mirror lacks are counted as backlog" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  mono_commit "feat: two" >/dev/null
  mono_commit "feat: three" >/dev/null

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "2" ]
  [ "$(out frontier)" = "$m1" ]
  [ "$(out degraded)" = "false" ]
}

@test "a backlog younger than the threshold is catching up, not stale" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  # Landed an hour ago: the export has not had time to run yet, and alerting
  # here would cry wolf on every normal merge.
  mono_commit "feat: two" 1 >/dev/null

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "1" ]
  [ "$(out stale)" = "false" ]
}

@test "a backlog older than the threshold is stale" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  mono_commit "feat: two" 50 >/dev/null

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "true" ]
  [ "$(out backlog-count)" = "1" ]
  [ "$(out oldest-unmirrored-age-hours)" -ge 49 ]
}

@test "staleness is judged on the oldest waiting commit, not the newest" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  # One commit stuck for days, another landed moments ago. The fresh one must
  # not reset the clock and hide the stall behind it.
  mono_commit "feat: old" 100 >/dev/null
  mono_commit "feat: fresh" 0 >/dev/null

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "true" ]
  [ "$(out backlog-count)" = "2" ]
}

@test "an abbreviated trailer value still matches its commit" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: ${m1:0:10}"

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "0" ]
  [ "$(out frontier)" = "$m1" ]
}

@test "a Monorepo-Commit line in the body is not read as a record" {
  local m1 m2
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  m2=$(mono_commit "feat: two" 100)
  # The mirror is public and takes outside contributions, so a message body is
  # contributor-controlled. A column-zero Monorepo-Commit line in one, orphaned
  # out of git's trailer block by a later paragraph, must not count as a record
  # we wrote: a record is what ends the walk, so reading this one reports a
  # mirror that is a commit behind as being in sync. The export cannot produce
  # this shape, so refusing it loses nothing.
  oss_record "fix: community contribution

Monorepo-Commit: $m2

Co-authored-by: someone <someone@example.com>"

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "1" ]
  [ "$(out stale)" = "true" ]
  [ "$(out frontier)" = "$m1" ]
  [ "$(out degraded)" = "false" ]
}

@test "the trailer key is matched case-insensitively" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

monorepo-commit: $m1"

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "0" ]
}

@test "an unreachable OSS branch degrades instead of reporting in sync" {
  OSS_REMOTE="$ROOT/does-not-exist.git" run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
}

@test "a missing branch on the OSS side degrades" {
  BRANCH=v9.99 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
}

@test "a shallow checkout degrades rather than inventing a frontier" {
  local m1 shallow
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  shallow="$ROOT/shallow"
  git clone -q --depth 1 "file://$MONO" "$shallow"
  cd "$shallow"

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
  [[ "$output" == *"shallow"* ]]
}

@test "no record within the scan window reports both stale and degraded" {
  # The mirror has records, but none naming a commit on this branch: the export
  # never got far enough, or the records belong to a different line. Either way
  # we cannot find a frontier, so we must not call it in sync.
  rm -rf "$OSS"
  git init -q --bare "$OSS"
  git init -q "$ROOT/foreign"
  (
    cd "$ROOT/foreign"
    git checkout -q -b main
    echo hi >f.txt
    git add . && git commit -qm "unrelated

Monorepo-Commit: 0000000000000000000000000000000000000000"
    git push -q "$OSS" main
  )
  cd "$MONO"
  mono_commit "feat: one" 100 >/dev/null
  mono_commit "feat: two" 100 >/dev/null

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "true" ]
  [ "$(out degraded)" = "true" ]
  [ "$(out frontier)" = "" ]
}

@test "a mirror with no records at all degrades" {
  # Fresh OSS branch with nothing the export ever wrote: we cannot say whether
  # it is behind, and must not say it is fine.
  oss_record "plain commit with no trailer"
  rm -rf "$ROOT/oss.git"
  git init -q --bare "$OSS"
  git init -q "$ROOT/blank"
  (
    cd "$ROOT/blank"
    git checkout -q -b main
    echo hi >f.txt
    git add . && git commit -qm "no trailer here"
    git push -q "$OSS" main
  )
  cd "$MONO"

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
}

@test "a non-numeric threshold degrades instead of comparing against garbage" {
  MAX_AGE_HOURS="soon" run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
}

@test "an overlong threshold is rejected before it can overflow" {
  MAX_AGE_HOURS="99999999999999999999" run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
}

@test "every output has a value even on a degraded run" {
  OSS_REMOTE="$ROOT/does-not-exist.git" run bash "$CHECK"
  [ "$status" -eq 0 ]
  # A caller reading `stale` after a degraded run must get a real answer, not an
  # empty string that silently compares equal to nothing.
  [ -n "$(out stale)" ]
  [ -n "$(out degraded)" ]
  [ -n "$(out backlog-count)" ]
  [ -n "$(out export-unconfirmed)" ]
}

@test "the token in the remote URL never reaches the step summary" {
  # file:// so the suite never leaves the machine; the scrubbing path is the
  # same, and a real fetch would make this pass for the wrong reason offline.
  export OSS_REMOTE="file://x-access-token:ghp_supersecrettoken@/nonexistent/vcluster.git"
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
  ! grep -q "ghp_supersecrettoken" "$GITHUB_STEP_SUMMARY"
  [[ "$output" != *"ghp_supersecrettoken"* ]]
}

@test "a wrong subtree prefix degrades instead of reporting in sync" {
  SUBTREE_PREFIX="staging/github.com/loft-sh/nothing-here" run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
}

@test "a commit that originated on OSS is not counted as backlog" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  # An imported community contribution. The exporter skips it, so no record for
  # it will ever appear on the mirror; counting it would alert forever on a
  # release line that is perfectly current.
  (
    cd "$MONO"
    echo "from a contributor" >>"$PFX/pkg/app.go"
    git add .
    GIT_AUTHOR_DATE="$(date -u -d '60 hours ago' +%s) +0000" \
      GIT_COMMITTER_DATE="$(date -u -d '60 hours ago' +%s) +0000" \
      git commit -qm "feat: contributed upstream

Oss-Commit: 1111111111111111111111111111111111111111"
  )

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "0" ]
  [ "$(out stale)" = "false" ]
  [ "$(out degraded)" = "false" ]
}

@test "a content-identical mirror is in sync even with no matching record" {
  # Covers the exporter's other skip rules (no-op applies, empty diffs) without
  # having to reproduce each one: if the trees agree, the mirror is current.
  mono_commit "feat: one" >/dev/null
  oss_mirror_content "export"

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "false" ]
  [ "$(out degraded)" = "false" ]
  [ "$(out backlog-count)" = "0" ]
  # Empty, not the tip: this path short-circuits on content and never walks far
  # enough to find a record, so naming the tip would report the newest commit
  # nothing recorded as the newest commit something did.
  [ -z "$(out frontier)" ]
}

@test "a tag sharing the branch name does not shadow the branch" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  # Release tags and release branches share a namespace shape here (v0.37 the
  # branch, v0.37.1 the tag), and git resolves a bare name against tags first.
  git -C "$MONO" tag main "$m1"
  mono_commit "feat: two" 100 >/dev/null
  mono_commit "feat: three" 100 >/dev/null

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "2" ]
  [ "$(out stale)" = "true" ]
}

@test "the deepest backlog still reports how long it has been waiting" {
  rm -rf "$OSS"
  git init -q --bare "$OSS"
  git init -q "$ROOT/foreign2"
  (
    cd "$ROOT/foreign2"
    git checkout -q -b main
    echo hi >f.txt
    git add . && git commit -qm "unrelated

Monorepo-Commit: 0000000000000000000000000000000000000000"
    git push -q "$OSS" main
  )
  cd "$MONO"
  mono_commit "feat: one" 90 >/dev/null

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "true" ]
  # Reporting "waiting 0h" for the worst case there is would read as trivial.
  [ "$(out oldest-unmirrored-age-hours)" -ge 89 ]
}

@test "a merge commit in the backlog is a stall, not an empty commit" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  # The exporter dies on a merge rather than skipping it, so this is the hardest
  # stall there is. diff-tree prints nothing for a merge, which made it look like
  # an empty commit and reported a stalled mirror as in sync.
  (
    cd "$MONO"
    git checkout -q -b topic
    echo "topic work" >>"$PFX/pkg/app.go"
    git add .
    git commit -qm "feat: on a topic branch"
    git checkout -q main
    local when
    when=$(date -u -d '60 hours ago' +%s)
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
      git merge -q --no-ff topic -m "merge topic"
  )

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "1" ]
  [ "$(out stale)" = "true" ]
  [[ "$output" == *"merge commit"* ]]
}

@test "a trailing slash on the prefix does not hide the backlog" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  mono_commit "feat: two" 50 >/dev/null
  mono_commit "feat: three" 50 >/dev/null

  SUBTREE_PREFIX="$PFX/" MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "2" ]
  [ "$(out stale)" = "true" ]
}

@test "an indented Oss-Commit line is not treated as having come from OSS" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  # The exporter drops indented lines as folded values, so it will still export
  # this commit. Reading it more permissively here would hide a commit the
  # export still owes the mirror, which is the one error this must not make.
  (
    cd "$MONO"
    echo "looks imported but is not" >>"$PFX/pkg/app.go"
    git add .
    local when
    when=$(date -u -d '60 hours ago' +%s)
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
      git commit -qm "feat: quoting a trailer

  Oss-Commit: 1111111111111111111111111111111111111111"
  )

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "1" ]
  [ "$(out stale)" = "true" ]
}

@test "a non-hex Oss-Commit value is not treated as having come from OSS" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  (
    cd "$MONO"
    echo "not a real record" >>"$PFX/pkg/app.go"
    git add .
    local when
    when=$(date -u -d '60 hours ago' +%s)
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
      git commit -qm "feat: malformed trailer

Oss-Commit: 2222222xyz"
  )

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "1" ]
}

@test "matching trees with no record for the tip say the export may be dead" {
  # A commit and its revert, both unexported: the trees agree again, so content
  # is genuinely current, but nothing recorded the tip. This is the one case
  # where a stopped export produces no other signal.
  mono_commit "feat: one" >/dev/null
  oss_mirror_content "export"
  (
    cd "$MONO"
    echo "adds a line" >>"$PFX/pkg/app.go"
    git add . && git commit -qm "feat: add"
    git revert --no-edit HEAD >/dev/null
  )

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "false" ]
  [ "$(out degraded)" = "false" ]
  [[ "$output" == *"no export recorded"* ]]
  # stale is false and degraded is false, both correctly, so without an output of
  # its own this finding would live in a scheduled run's log and nowhere else.
  [ "$(out export-unconfirmed)" = "true" ]
}

@test "the check ships executable, since the action runs it directly" {
  # action.yml runs the script as a command rather than through `bash`, so a
  # 100644 blob makes every run die with Permission denied: a red step reporting
  # neither stale nor degraded, which is the silence this action exists to break.
  # Every other test here calls `bash "$CHECK"` and would never notice.
  [ -x "$CHECK" ]
  local mode
  mode=$(git -C "$BATS_TEST_DIRNAME" ls-files -s -- ../src/oss-mirror-staleness.sh | cut -d' ' -f1)
  [ "$mode" = "100755" ]
}

@test "an empty required input degrades instead of dying before it can report" {
  # A misspelled matrix key reaches the action as an empty string. Aborting here
  # leaves a caller gating on stale or degraded seeing neither.
  BRANCH= run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "true" ]
  [ "$(out stale)" = "false" ]
  [[ "$output" == *"BRANCH"* ]]
}

@test "paths the export never mirrors do not defeat the content short-circuit" {
  # The exporter is given exclude-paths and holds the trees to agree everywhere
  # else. Demanding whole-tree equality here would never match on a repo that
  # configures them, dropping the check onto the walk, where every commit the
  # exporter skips without a record counts as backlog that cannot drain.
  mono_commit "feat: one" >/dev/null
  oss_mirror_content "export"
  local clone="$ROOT/ossx"
  git clone -q "$OSS" "$clone"
  (
    cd "$clone"
    git checkout -q main
    mkdir -p .github/workflows
    # One mirror-only file per entry in the list below. A file under only the
    # first would leave the second entry unexercised: the trees would agree
    # whether or not it was ever applied, and an implementation that honoured
    # one line and dropped the rest would pass. Production passes seven.
    echo "on: push" >.github/workflows/release.yaml
    echo "on: push" >.github/workflows/push-head-images.yaml
    git add . && git commit -qm "chore: producer workflows, mirror only"
    git push -q origin main
  )

  EXCLUDE_PATHS=".github/workflows/release.yaml
.github/workflows/push-head-images.yaml" run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "false" ]
  [ "$(out degraded)" = "false" ]
  [ "$(out backlog-count)" = "0" ]
}

@test "an Oss-Commit shape the exporter reads is not counted as backlog" {
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  # Two shapes git reads and a hand-written regex does not: whitespace before the
  # colon, and a value folded onto the next line. The exporter reads both, skips
  # the commit and records nothing, so missing them here parks two commits in the
  # backlog for good and alerts forever on a branch that is current.
  local when
  when=$(date -u -d '60 hours ago' +%s)
  (
    cd "$MONO"
    echo "spaced" >>"$PFX/pkg/app.go"
    git add .
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
      git commit -qm "feat: space before the colon

Oss-Commit : 1111111111111111111111111111111111111111"
    echo "folded" >>"$PFX/pkg/app.go"
    git add .
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
      git commit -qm "feat: folded value

Oss-Commit:
 2222222222222222222222222222222222222222"
  )

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out backlog-count)" = "0" ]
  [ "$(out stale)" = "false" ]
  [ "$(out degraded)" = "false" ]
}

@test "a commit that never touches the subtree is not a dead-export signal" {
  # The steady state on the monorepo branch: most commits are pro-only, so the
  # tip is usually one the export neither mirrors nor records. Asking whether the
  # TIP has a record makes the dead-export warning print on nearly every run,
  # which is how a real signal gets trained out of its readers.
  local m1
  m1=$(mono_commit "feat: one")
  oss_mirror_content "export

Monorepo-Commit: $m1"
  (
    cd "$MONO"
    echo "pro change" >>pro.txt
    git add . && git commit -qm "feat: pro only"
  )

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out stale)" = "false" ]
  [ "$(out degraded)" = "false" ]
  [[ "$output" != *"no export recorded"* ]]
  [ "$(out export-unconfirmed)" = "false" ]
  # The newest commit the export actually owed a record for, not the branch tip.
  [ "$(out frontier)" = "$m1" ]
}

@test "an imported commit at the tip is not a dead-export signal either" {
  # The export skips it by design and records nothing, which is not evidence of
  # anything being wrong.
  local m1
  m1=$(mono_commit "feat: one")
  oss_mirror_content "export

Monorepo-Commit: $m1"
  (
    cd "$MONO"
    echo "from a contributor" >>"$PFX/pkg/app.go"
    git add . && git commit -qm "feat: contributed upstream

Oss-Commit: 1111111111111111111111111111111111111111"
  )
  oss_mirror_content "already there"

  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(out degraded)" = "false" ]
  [[ "$output" != *"no export recorded"* ]]
  [ "$(out frontier)" = "$m1" ]
}

@test "the step summary carries one heading, however much it has to say" {
  # A merge blocker and the staleness verdict are two calls, and a heading per
  # call renders the same H3 twice with a fragment under each.
  local m1
  m1=$(mono_commit "feat: one")
  oss_record "feat: one

Monorepo-Commit: $m1"
  (
    cd "$MONO"
    git checkout -qb side
    echo "side" >>"$PFX/pkg/app.go"
    git add . && git commit -qm "feat: side"
    git checkout -q main
    local when
    when=$(date -u -d '80 hours ago' +%s)
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
      git merge -q --no-ff -m "merge: side into main" side
  )

  MAX_AGE_HOURS=24 run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^### OSS mirror staleness' "$ROOT/summary.md")" = "1" ]
  # Both things it had to say are still there.
  grep -q "merge commit" "$ROOT/summary.md"
  grep -q "Stale" "$ROOT/summary.md"
}


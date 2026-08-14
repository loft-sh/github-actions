#!/usr/bin/env bats
# Unit tests for lib.sh trailer lookup.
#
# Two regressions are pinned here:
#
#   * the large-history SIGPIPE one: newest_trailer_entry must not close the
#     git-log pipe early (exit 141 under pipefail on big repos, build-dependent)
#
#   * the squash-orphaned-trailer one: GitHub's "Squash and merge" appends
#     "Co-authored-by:" as a new paragraph, which moves our trailer out of the
#     block git's own %(trailers) parser reads. The lookup must still find it.

setup() {
  ROOT=$(mktemp -d); export ROOT
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_CONFIG_GLOBAL="$ROOT/gc"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  # shellcheck disable=SC1090
  source "$BATS_TEST_DIRNAME/../lib.sh"
  git init -q "$ROOT/r"; cd "$ROOT/r"

  # Trailer values are always commit shas, which is the shape the lookup keys
  # on; use realistic ones rather than placeholder words.
  OLD_SHA=1111111111111111111111111111111111111111
  NEW_SHA=2222222222222222222222222222222222222222
  OTHER_SHA=3333333333333333333333333333333333333333
}
teardown() { rm -rf "$ROOT"; }

@test "newest_trailer_entry returns the newest match" {
  git commit -q --allow-empty -m "old

Monorepo-Commit: $OLD_SHA"
  git commit -q --allow-empty -m "new

Monorepo-Commit: $NEW_SHA"
  run newest_trailer_entry HEAD Monorepo-Commit
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | awk '{print $2}')" = "$NEW_SHA" ]
}

@test "newest_trailer_entry is empty when no trailer present" {
  git commit -q --allow-empty -m "no trailer here"
  run newest_trailer_entry HEAD Monorepo-Commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "trailer orphaned by a squash-appended Co-authored-by paragraph is found" {
  # Exactly what GitHub's squash-merge produced on vcluster-pro main: our
  # trailer, a blank line, then the co-author block. git's %(trailers) sees only
  # the last paragraph and misses Oss-Commit entirely.
  git commit -q --allow-empty -m "fix: something (#4037) (#2113)

body text

Oss-Commit: $NEW_SHA

Co-authored-by: Florian <f@example.com>"

  # Confirm the premise: git's own parser really does not see it.
  [ -z "$(git log -1 --format='%(trailers:key=Oss-Commit,valueonly)' HEAD | tr -d '[:space:]')" ]

  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW_SHA" ]

  run has_trailer HEAD Oss-Commit
  [ "$status" -eq 0 ]
}

@test "prose mentioning a trailer key is not matched" {
  git commit -q --allow-empty -m "docs: explain the sync

Each replayed commit gets an Oss-Commit: <sha> trailer appended, and the
importer reads Oss-Commit trailers to find its resume point.

Signed-off-by: t <t@t>"
  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an indented trailer line is not matched" {
  # Quoted/indented message bodies (a reply, a code block) must not be read as
  # sync state; a real trailer always starts at column 0.
  git commit -q --allow-empty -m "chore: quote a message

    Oss-Commit: $OTHER_SHA"
  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "key match is case-insensitive, like git's own trailer parsing" {
  git commit -q --allow-empty -m "chore: lowercase key

oss-commit: $NEW_SHA"
  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW_SHA" ]
}

@test "several same-key lines on one commit: the last one wins" {
  # GitHub's default squash message concatenates the branch's commit messages,
  # so the newest import trailer is the last occurrence.
  git commit -q --allow-empty -m "chore: sync from oss (#42)

feat: first

Oss-Commit: $OLD_SHA

feat: second

Oss-Commit: $NEW_SHA"
  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW_SHA" ]
}

@test "all_trailer_entries lists every carrier newest first" {
  git commit -q --allow-empty -m "one

Oss-Commit: $OLD_SHA"
  git commit -q --allow-empty -m "two

Oss-Commit: $NEW_SHA

Co-authored-by: someone <s@example.com>"
  run all_trailer_entries HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l)" -eq 2 ]
  [ "$(echo "$output" | awk 'NR==1 {print $2}')" = "$NEW_SHA" ]
  [ "$(echo "$output" | awk 'NR==2 {print $2}')" = "$OLD_SHA" ]
}

@test "every_trailer_value reports all same-key lines on one commit" {
  # The squash shape again, but read as a set instead of a resume point: both
  # replayed commits were absorbed, so both must come back. Last-wins here is
  # what deadlocked the export divergence guard.
  git commit -q --allow-empty -m "chore: sync from oss (#42)

feat: first

Oss-Commit: $OLD_SHA

revert: first

Oss-Commit: $NEW_SHA

Co-authored-by: alice <alice@contributor.example>"
  run every_trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l)" -eq 2 ]
  [ "$(echo "$output" | awk 'NR==1')" = "$OLD_SHA" ]
  [ "$(echo "$output" | awk 'NR==2')" = "$NEW_SHA" ]
  # The resume-point lookup keeps its last-wins contract.
  [ "$(trailer_value HEAD Oss-Commit)" = "$NEW_SHA" ]
}

@test "every_trailer_value spans commits newest first and keeps the shape filters" {
  git commit -q --allow-empty -m "one

Oss-Commit: $OLD_SHA"
  git commit -q --allow-empty -m "two

    Oss-Commit: $OTHER_SHA

Oss-Commit: $NEW_SHA"
  run every_trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l)" -eq 2 ]
  [ "$(echo "$output" | awk 'NR==1')" = "$NEW_SHA" ]
  [ "$(echo "$output" | awk 'NR==2')" = "$OLD_SHA" ]
  # The indented line is a quoted body, not sync state.
  [[ "$output" != *"$OTHER_SHA"* ]]
}

@test "an abbreviated hand-written trailer is still read" {
  git commit -q --allow-empty -m "chore: hand-written import

Oss-Commit: 7b20042"
  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$output" = "7b20042" ]
}

@test "resolve_sha_set expands an abbreviated value to its full sha" {
  git commit -q --allow-empty -m "a commit to abbreviate"
  full=$(git rev-parse HEAD)
  run resolve_sha_set <<< "${full:0:12}"
  [ "$status" -eq 0 ]
  # Both forms, so a set built from trailer values matches full shas from
  # git rev-list as well as the abbreviation as written.
  [ "$(echo "$output" | wc -l)" -eq 2 ]
  [ "$(echo "$output" | awk 'NR==1')" = "${full:0:12}" ]
  [ "$(echo "$output" | awk 'NR==2')" = "$full" ]
}

@test "resolve_sha_set passes through what it cannot resolve and stays quiet" {
  # A trailer may name a commit this repo does not hold; it must keep matching
  # literally rather than dropping out of the set.
  run resolve_sha_set <<< "$OLD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "$OLD_SHA" ]
}

@test "resolve_sha_set stays quiet when an abbreviation names a non-commit" {
  # --quiet does not cover a type mismatch: unguarded, rev-parse prints
  # "expected commit type" and the export log grows a bare error line.
  git commit -q --allow-empty -m "a commit"
  tree=$(git rev-parse "HEAD^{tree}")
  run resolve_sha_set <<< "${tree:0:12}"
  [ "$status" -eq 0 ]
  [ "$output" = "${tree:0:12}" ]
  [[ "$output" != *"error"* ]]
  [[ "$output" != *"expected commit type"* ]]
}

@test "resolve_sha_set never emits a sha the value is not a prefix of" {
  # ^{commit} also peels an annotated tag to a commit sharing none of its
  # digits. Emitting that would put a commit no trailer names into the absorbed
  # set, and align-tree=true converges by overwriting OSS rather than failing.
  git commit -q --allow-empty -m "tagged commit"
  commit=$(git rev-parse HEAD)
  git tag -a v1 -m "annotated" HEAD
  tag=$(git rev-parse v1)
  [ "$tag" != "$commit" ]

  # Abbreviated, or the full-length pass-through would skip the lookup and the
  # prefix guard would never run.
  run resolve_sha_set <<< "${tag:0:12}"
  [ "$status" -eq 0 ]
  [ "$output" = "${tag:0:12}" ]
  [[ "$output" != *"$commit"* ]]
}

@test "resolve_sha_set keeps a final line with no trailing newline" {
  # A dropped sha here is the deadlock this helper exists to close, and it reads
  # as a generic stdin filter, so it must not depend on its producer's newline.
  git commit -q --allow-empty -m "a commit"
  full=$(git rev-parse HEAD)
  run resolve_sha_set < <(printf '%s' "${full:0:12}")
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | awk 'NR==1')" = "${full:0:12}" ]
  [ "$(echo "$output" | awk 'NR==2')" = "$full" ]
}

@test "resolve_commit_prefix rejects a value that names no commit by prefix" {
  git commit -q --allow-empty -m "tagged"
  commit=$(git rev-parse HEAD)
  git tag -a v1 -m annotated HEAD
  tag=$(git rev-parse v1)

  run resolve_commit_prefix "${tag:0:12}"
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  run resolve_commit_prefix "${commit:0:12}"
  [ "$status" -eq 0 ]
  [ "$output" = "$commit" ]
}

@test "filter_sha_values keeps sha-shaped values and drops everything else" {
  run filter_sha_values <<'VALUES'
1111111111111111111111111111111111111111
2222222222222222222222222222222222222222222
abc123
7b20042
DEADBEEFCAFE
@{9999}
:/subject search
1111111111111111111111111111111111111111 with a folded tail
VALUES
  [ "$status" -eq 0 ]
  # Kept: the 40-char value, the 7-char abbreviation, and the uppercase run
  # (lowercased), since git's own parser accepts uppercase hex.
  [ "$(echo "$output" | wc -l)" -eq 3 ]
  [ "$(echo "$output" | awk 'NR==1')" = "1111111111111111111111111111111111111111" ]
  [ "$(echo "$output" | awk 'NR==2')" = "7b20042" ]
  [ "$(echo "$output" | awk 'NR==3')" = "deadbeefcafe" ]
  # Dropped: 43 chars (over 40), 6 chars (under TRAILER_SHA_MIN_LEN), non-hex, and
  # anything with a tail. The last two matter most: reflog syntax reaching
  # rev-parse exits 128, which the resolver escalates into a failed export.
  [[ "$output" != *"2222222222222222222222222222222222222222222"* ]]
  [[ "$output" != *"abc123"* ]]
  [[ "$output" != *"@"* ]]
  [[ "$output" != *"folded tail"* ]]
}

@test "resolve_commit_prefix separates naming no commit from git failing" {
  git commit -q --allow-empty -m "a commit"
  full=$(git rev-parse HEAD)

  # Absent, ambiguous and type-mismatch are all "names no commit": rc 1.
  run resolve_commit_prefix "${OLD_SHA:0:12}"
  [ "$status" -eq 1 ]

  # A broken object store is git failing: rc 2, so no caller can read it as an
  # answer about the value.
  GIT_OBJECT_DIRECTORY=/nonexistent run resolve_commit_prefix "${full:0:12}"
  [ "$status" -eq 2 ]
}

@test "resolve_sha_set fails the run when git breaks instead of shrinking the set" {
  # Silently dropping a resolved sha reports an absorbed commit as unabsorbed,
  # which is the deadlock this action exists to avoid, with a misleading message
  # on top. Aborting is the honest outcome.
  git commit -q --allow-empty -m "a commit"
  full=$(git rev-parse HEAD)
  GIT_OBJECT_DIRECTORY=/nonexistent run resolve_sha_set <<< "${full:0:12}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to judge divergence"* ]]
}

@test "resolve_sha_set spawns no lookup for a full-length value" {
  # The normal case: every trailer this action writes is already full length, so
  # resolution must not cost a git process per absorbed commit.
  git commit -q --allow-empty -m "a commit"
  full=$(git rev-parse HEAD)
  # A marker file, not stderr: bats does not fold a shim's stderr into $output
  # here, so an stderr-based probe passes even when git IS called.
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/git" <<WRAP
#!/usr/bin/env bash
echo "\$*" >> "$ROOT/git-was-called"
exit 99
WRAP
  chmod +x "$ROOT/bin/git"
  PATH="$ROOT/bin:$PATH" run resolve_sha_set <<< "$full"
  [ "$status" -eq 0 ]
  [ "$output" = "$full" ]
  [ ! -f "$ROOT/git-was-called" ]
}

@test "resolve_sha_set emits a full sha once, not twice" {
  git commit -q --allow-empty -m "already full"
  full=$(git rev-parse HEAD)
  run resolve_sha_set <<< "$full"
  [ "$status" -eq 0 ]
  [ "$output" = "$full" ]
}

@test "newest_trailer_entry survives a large history under pipefail (SIGPIPE regression)" {
  # Fabricate ~2500 commits cheaply; newest carries the trailer so a naive
  # early-exit consumer would close the pipe after line 1 while git streams
  # the rest (>64KB) -> SIGPIPE -> 141 under pipefail.
  et=$(git mktree </dev/null)
  prev=$(git commit-tree "$et" -m root)
  for i in $(seq 1 2500); do prev=$(git commit-tree "$et" -p "$prev" -m "c$i"); done
  head=$(git commit-tree "$et" -p "$prev" -m "newest

Monorepo-Commit: $NEW_SHA")
  git update-ref refs/heads/main "$head"
  set -o pipefail
  run newest_trailer_entry main Monorepo-Commit
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | awk '{print $2}')" = "$NEW_SHA" ]
}

@test "the last record wins even when only git's parser sees it" {
  # git's block IS the final paragraph, so a value there is later than any body line
  # above it. Preferring the earlier body line moves the import anchor forward past
  # commits still waiting to be imported.
  git commit -q --allow-empty -m "chore: two records, newest in a lax form

Oss-Commit: $OLD_SHA

prose in between

Oss-Commit:$NEW_SHA"
  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW_SHA" ]
}

@test "a control byte inside a trailer value cannot end the block early" {
  # git preserves control bytes in values. A prefix-only delimiter test would treat
  # such a value as the frame terminator and hide every record after it.
  printf 'chore: hostile value\n\nOss-Commit: \002not-a-sha\nOss-Commit:%s\n' "$NEW_SHA" > "$ROOT/msg"
  git commit -q --allow-empty -F "$ROOT/msg"
  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW_SHA" ]
}

@test "an uppercase in-block value is read, lowercased" {
  git commit -q --allow-empty -m "chore: uppercase record

Oss-Commit:$(echo "$NEW_SHA" | tr 'a-f' 'A-F')"
  run trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ "$output" = "$NEW_SHA" ]
}

@test "a forged frame byte cannot inject a record with no key present" {
  # \001 is legal at column 0 of a commit message, and import.sh replays OSS
  # messages verbatim, so this content is contributor-controlled. A leading-byte
  # frame test let such a line reopen the block, after which a bare hex line was
  # read as a keyless block value: an absorbed-set entry with no Oss-Commit
  # anywhere in the message. With align-tree that authorises deleting OSS content.
  printf 'feat: innocent looking\n\n\001bogus\n%s\n' "$NEW_SHA" > "$ROOT/msg"
  git commit -q --allow-empty -F "$ROOT/msg"
  run every_trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a frame byte mid-message does not swallow the records after it" {
  # The same forged frame, read from the other side: it used to reset the scan
  # mid-commit, so every trailer below it was dropped and the export reported
  # commits it had genuinely absorbed as divergence.
  printf 'squashed import\n\nOss-Commit: %s\n\001noise\nOss-Commit: %s\n\nCo-authored-by: x <x@y>\n' \
    "$OLD_SHA" "$NEW_SHA" > "$ROOT/msg"
  git commit -q --allow-empty -F "$ROOT/msg"
  run every_trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF "$OLD_SHA"
  echo "$output" | grep -qxF "$NEW_SHA"
}

@test "an orphaned record is read in every form git itself accepts" {
  # The whole-message scan exists for records a squash orphaned from git's block.
  # It was stricter than git in exactly that spot -- requiring ": " and lowercase
  # hex -- so a record git reads perfectly became invisible the moment it was
  # orphaned, which is the deadlock this scan was added to prevent.
  printf 'squashed\n\nOss-Commit: %s\nOss-Commit:%s\nOss-Commit:\t%s\n\nCo-authored-by: x <x@y>\n' \
    "$(echo "$OLD_SHA" | tr 'a-f' 'A-F')" "$NEW_SHA" "$OTHER_SHA" > "$ROOT/msg"
  git commit -q --allow-empty -F "$ROOT/msg"
  # git's own block sees none of them: the Co-authored-by paragraph orphaned all three.
  [ -z "$(git log -1 --format='%(trailers:key=Oss-Commit,valueonly,unfold)' | tr -d '[:space:]')" ]
  run every_trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF "$OLD_SHA"
  echo "$output" | grep -qxF "$NEW_SHA"
  echo "$output" | grep -qxF "$OTHER_SHA"
}

@test "a folded value is not a record for the body scan either" {
  # git folds the indented line into the value, so the value is not a sha and not
  # a record. Handing the bare first line to the shape filter promoted a sha
  # nobody recorded to absorption strong enough for align-tree to delete against.
  printf 'chore: folded\n\nOss-Commit: %s\n  this line makes it a folded value\n' "$NEW_SHA" > "$ROOT/msg"
  git commit -q --allow-empty -F "$ROOT/msg"
  run every_trailer_value HEAD Oss-Commit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lines_contain finds an early match in a haystack past the pipe buffer" {
  # The SIGPIPE regression, at the only place it is cheap to pin: grep -q exits at
  # the first match, so a writer still pushing a >64KB haystack dies of SIGPIPE and
  # pipefail turns a found value into a failed lookup. health.sh reads that as "git
  # never saw this record" and reports a clean rebase-merge as a squash.
  needle="$NEW_SHA"
  haystack="$needle"
  for i in $(seq 1 3000); do haystack="${haystack}"$'\n'"$OTHER_SHA"; done
  [ "${#haystack}" -gt 65536 ]
  set -o pipefail
  run lines_contain "$haystack" "$needle"
  [ "$status" -eq 0 ]
}

@test "lines_contain says no when the needle is not a whole line" {
  run lines_contain "${NEW_SHA}extra"$'\n'"prefix${NEW_SHA}" "$NEW_SHA"
  [ "$status" -ne 0 ]
}

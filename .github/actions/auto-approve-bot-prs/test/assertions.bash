# Shared negative assertion. Lives here rather than in one .bats file because
# every script in this action interpolates externally-controlled text into log
# lines, so every suite needs it.

# assert_no_match <perl-regex> <text> — fail the test if the regex matches.
#
# Do NOT write `! grep -q ... <<<"$output"` instead. Bash does not abort on a
# command whose status is inverted with `!`, so under the `set -e` that bats runs
# test bodies with, a bare negated grep is a no-op unless it happens to be the
# final line. Several assertions were silently inert that way. A plain function
# call returning non-zero does abort, so this one actually fails.
#
# The same trap applies to negating a *helper function* (`! auto_merge_attempted`)
# — the `!` is what disables `set -e`, not the grep. Wrap those in a helper that
# calls this, rather than negating them at the call site.
assert_no_match() {
  local rc=0
  grep -qP -- "$1" <<<"$2" || rc=$?
  case "$rc" in
    0) printf 'assert_no_match: unexpected match for %s\n' "$1" >&2; return 1 ;;
    1) return 0 ;;
    # grep returns 2 for a malformed pattern. Treating that as "no match" is the
    # very fail-open shape this helper exists to prevent, so it must fail loudly.
    *) printf 'assert_no_match: grep error rc=%s for pattern %s\n' "$rc" "$1" >&2; return 1 ;;
  esac
}

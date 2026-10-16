#!/usr/bin/env bats
# Tests for release-lib/lib.sh on its own, with a line-branch convention other
# than platform-release's. The routing and probes are covered in depth by the
# platform-release suite; this one pins the contract a second caller relies on:
# every branch name comes from the sourcing script's globals.

setup() {
  source "${BATS_TEST_DIRNAME}/../lib.sh"
  DEFAULT_BRANCH="trunk"
  LINE_BRANCH_FORMAT="v%s.%s"
  LINE_BRANCH_PATTERN='^v[0-9]+\.[0-9]+$'
}

@test "derive_line: follows LINE_BRANCH_FORMAT" {
  run derive_line "v0.37.2-rc.1"
  [ "$status" -eq 0 ]
  [ "$output" = "v0.37" ]
}

@test "is_feature_branch: the default and line branches come from the globals" {
  run is_feature_branch trunk
  [ "$status" -eq 1 ]
  run is_feature_branch v0.37
  [ "$status" -eq 1 ]
  # main is an ordinary branch name once it is not the default.
  run is_feature_branch main
  [ "$status" -eq 0 ]
  run is_feature_branch release-4.11
  [ "$status" -eq 0 ]
}

@test "resolve_target: alpha goes to DEFAULT_BRANCH and names it when refusing" {
  run resolve_target alpha "" v0.37
  [ "$status" -eq 0 ]
  [ "$output" = "trunk" ]
  run resolve_target alpha main v0.37
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from trunk only, not 'main'"* ]]
}

@test "resolve_target: rc and stable route to the line branch they are given" {
  run resolve_target rc v0.37 v0.37
  [ "$status" -eq 0 ]
  [ "$output" = "v0.37" ]
  run resolve_target stable "" v0.37
  [ "$status" -eq 0 ]
  [ "$output" = "v0.37" ]
}

@test "validate_version: the semver gate does not depend on the caller" {
  run validate_version "v0.37.02"
  [ "$status" -ne 0 ]
  run validate_version "v0.37.0-rc."
  [ "$status" -ne 0 ]
  run validate_version "v0.37.0-rc.1"
  [ "$status" -eq 0 ]
}

@test "classify_suffix: a dashed unrouted flavor is not an alpha" {
  run classify_suffix "v0.37.0-devpod-alpha.1"
  [ "$status" -ne 0 ]
}

@test "a caller that forgets a global fails loudly under set -u" {
  # The lib defines no defaults, so a missing global must not fall back to an
  # empty string and route everything to "".
  # The exit code for an unbound variable varies by bash version, so the inner
  # shell's status is reported rather than pinned.
  run bash -c '( set -u; source "$1"; is_feature_branch main ) 2>&1; echo "rc=$?"' _ "${BATS_TEST_DIRNAME}/../lib.sh"
  [[ "$output" == *"DEFAULT_BRANCH"* ]]
  [[ "$output" != *"rc=0"* ]]
}

@test "run_captured: stdout and stderr land in separate variables" {
  local out err
  run_captured out err bash -c 'echo body; echo notice >&2'
  [ "$out" = "body" ]
  [ "$err" = "notice" ]
}

@test "run_captured: the command's exit status is returned and stdin passes through" {
  local out err rc=0
  run_captured out err bash -c 'cat; echo failed >&2; exit 3' <<<"from stdin" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$out" = "from stdin" ]
  [ "$err" = "failed" ]
}

# stub_gh <body> - put a `gh` on PATH that runs <body> with the call's args, and
# logs every call to $GH_LOG.
stub_gh() {
  STUB_DIR="$(mktemp -d)"
  GH_LOG="${STUB_DIR}/log"
  export GH_LOG
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$GH_LOG"\n%s\n' "$1" >"${STUB_DIR}/gh"
  chmod +x "${STUB_DIR}/gh"
  PATH="${STUB_DIR}:${PATH}"
}

@test "tag_runs: queries the workflow it is given, under both tag spellings" {
  stub_gh 'printf "{\"workflow_runs\":[{\"id\":7,\"run_attempt\":1,\"head_sha\":\"abc\",\"status\":\"queued\",\"conclusion\":null}]}\n" | jq -r "${@: -1}"'
  local runs
  tag_runs runs org/repo build.yaml v0.37.2
  grep -q 'workflows/build.yaml/runs?branch=v0.37.2&' "$GH_LOG"
  grep -q 'workflows/build.yaml/runs?branch=refs/tags/v0.37.2&' "$GH_LOG"
  # Every page is read, not just the first.
  [ "$(grep -c -- '--paginate' "$GH_LOG")" -eq 2 ]
  # The same run under both queries is counted once.
  [ "$runs" = "7 abc queued none 1" ]
  [ "$(count_runs_at "$runs" abc)" -eq 1 ]
}

@test "tag_runs: a run that finishes between the two reads is kept once, as still going" {
  # Read first under the short name, then under refs/tags/, by when it was done.
  stub_gh 'if [[ "$*" == *refs/tags/* ]]; then s=completed c="\"success\""; else s=in_progress c=null; fi
printf "{\"workflow_runs\":[{\"id\":7,\"run_attempt\":1,\"head_sha\":\"abc\",\"status\":\"%s\",\"conclusion\":%s},{\"id\":8,\"run_attempt\":1,\"head_sha\":\"abc\",\"status\":\"completed\",\"conclusion\":\"failure\"}]}\n" "$s" "$c" | jq -r "${@: -1}"'
  local runs
  tag_runs runs org/repo build.yaml v0.37.2
  [ "$runs" = $'7 abc in_progress none 1\n8 abc completed failure 1' ]
  [ "$(count_runs_at "$runs" abc)" -eq 2 ]
}

@test "tag_runs: the live copy of a run wins whichever read it came from" {
  stub_gh 'if [[ "$*" == *refs/tags/* ]]; then s=in_progress c=null; else s=completed c="\"success\""; fi
printf "{\"workflow_runs\":[{\"id\":7,\"run_attempt\":1,\"head_sha\":\"abc\",\"status\":\"%s\",\"conclusion\":%s}]}\n" "$s" "$c" | jq -r "${@: -1}"'
  local runs
  tag_runs runs org/repo build.yaml v0.37.2
  [ "$runs" = "7 abc in_progress none 1" ]
}

@test "tag_runs: a re-run started between the two reads is kept as queued" {
  # A re-run keeps the run id, so the completed copy is the older one here.
  stub_gh 'if [[ "$*" == *refs/tags/* ]]; then a=2 s=queued c=null; else a=1 s=completed c="\"failure\""; fi
printf "{\"workflow_runs\":[{\"id\":7,\"run_attempt\":%s,\"head_sha\":\"abc\",\"status\":\"%s\",\"conclusion\":%s}]}\n" "$a" "$s" "$c" | jq -r "${@: -1}"'
  local runs
  tag_runs runs org/repo build.yaml v0.37.2
  [ "$runs" = "7 abc queued none 2" ]
}

@test "tag_runs: a re-run is kept as queued whichever read it came from" {
  stub_gh 'if [[ "$*" == *refs/tags/* ]]; then a=1 s=completed c="\"failure\""; else a=2 s=queued c=null; fi
printf "{\"workflow_runs\":[{\"id\":7,\"run_attempt\":%s,\"head_sha\":\"abc\",\"status\":\"%s\",\"conclusion\":%s}]}\n" "$a" "$s" "$c" | jq -r "${@: -1}"'
  local runs
  tag_runs runs org/repo build.yaml v0.37.2
  [ "$runs" = "7 abc queued none 2" ]
}

@test "tag_runs: a run without run_attempt is an unknown answer, not a first attempt" {
  stub_gh 'printf "{\"workflow_runs\":[{\"id\":7,\"head_sha\":\"abc\",\"status\":\"completed\",\"conclusion\":\"failure\"}]}\n" | jq -r "${@: -1}"'
  local runs
  run tag_runs runs org/repo build.yaml v0.37.2
  [ "$status" -ne 0 ]
}

@test "tag_runs: an error-shaped body is an unknown answer, not no runs" {
  stub_gh 'printf "{\"message\":\"Server Error\"}\n" | jq -r "${@: -1}"'
  local runs
  run tag_runs runs org/repo build.yaml v0.37.2
  [ "$status" -ne 0 ]
}

@test "require_tag_on_target: a gone line branch named by the globals is refused" {
  stub_gh 'echo "HTTP/2.0 404 Not Found"; exit 1'
  run require_tag_on_target org/repo v0.37 v0.37.2 abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"branch 'v0.37' not found"* ]]
  run require_tag_on_target org/repo trunk v0.37.2 abc
  [ "$status" -ne 0 ]
}

@test "require_tag_on_target: a gone feature branch only warns" {
  # release-4.11 is a feature branch under this caller's convention.
  stub_gh 'echo "HTTP/2.0 404 Not Found"; exit 1'
  run require_tag_on_target org/repo release-4.11 v0.37.2-next.1 abc
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::branch 'release-4.11' no longer exists"* ]]
}

@test "api_read: a 200 gives the body, a 404 is 1, anything else is 2 with the cause" {
  stub_gh 'case "$*" in
  *ok*) printf "HTTP/2.0 200 OK\n\n"; echo "{\"a\":1}" | jq -r "${@: -1}" ;;
  *gone*) echo "HTTP/2.0 404 Not Found"; exit 1 ;;
  *denied*) echo "HTTP/2.0 403 Forbidden"; echo "gh: Resource protected by SAML" >&2; exit 1 ;;
  *) echo "gh: dial tcp" >&2; exit 1 ;;
esac'
  local out rc
  rc=0; api_read out repos/ok "the thing" .a || rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "1" ]
  rc=0; api_read out repos/gone "the thing" .a || rc=$?
  [ "$rc" -eq 1 ]
  [ "$API_READ_ERR" = "GitHub answered 404 for the thing" ]
  rc=0; api_read out repos/denied "the thing" .a || rc=$?
  [ "$rc" -eq 2 ]
  [[ "$API_READ_ERR" == *"unexpected status 403"*"SAML"* ]]
  rc=0; api_read out repos/down "the thing" .a || rc=$?
  [ "$rc" -eq 2 ]
  [[ "$API_READ_ERR" == *"no HTTP status"*"dial tcp"* ]]
}

# stub_tag <tag-object-answer> - an annotated tag whose tag object is answered
# with <tag-object-answer>, a stub_gh case arm body.
stub_tag() {
  stub_gh 'case "$*" in
  *git/ref/tags/*) printf "HTTP/2.0 200 OK\n\n"; echo "{\"object\":{\"sha\":\"2222222222222222222222222222222222222222\",\"type\":\"tag\"}}" | jq -r "${@: -1}" ;;
  *git/tags/*) '"$1"' ;;
esac'
}

@test "resolve_tag: a tag object that cannot be read is a failed read" {
  stub_tag 'echo "gh: dial tcp" >&2; exit 1'
  local sha rc=0
  resolve_tag sha org/repo v0.37.2 || rc=$?
  [ "$rc" -eq 2 ]
  [[ "$TAG_ERR" == *"tag object v0.37.2 in org/repo"*"dial tcp"* ]]
}

@test "resolve_tag: a tag object that is gone is a tag no run builds" {
  stub_tag 'echo "HTTP/2.0 404 Not Found"; exit 1'
  local sha rc=0
  resolve_tag sha org/repo v0.37.2 || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$TAG_ERR" == *"could not be resolved"* ]]
}

@test "resolve_tag: an annotated tag is peeled to its commit" {
  stub_tag 'printf "HTTP/2.0 200 OK\n\n"; echo "{\"object\":{\"sha\":\"1111111111111111111111111111111111111111\",\"type\":\"commit\"}}" | jq -r "${@: -1}"'
  local sha rc=0
  resolve_tag sha org/repo v0.37.2 || rc=$?
  [ "$rc" -eq 0 ]
  [ "$sha" = "1111111111111111111111111111111111111111" ]
}

# rc_stub - make gh a function, which run_captured calls like the binary, that
# answers the two reads the rc guard makes through the caller's own --jq. RC_REFS
# names the rc tags the listing returns, COMPARE is "<status> <ahead> <behind>",
# and RC_LIST_FAILS / COMPARE_FAILS fail that read the way an unreachable API
# does. Every path is logged to GH_LOG so a test can pin which rc was compared.
rc_stub() {
  GH_LOG="${BATS_TEST_TMPDIR}/gh.log"
  gh() {
    local path
    for path in "$@"; do [[ "$path" == repos/* ]] && break; done
    printf '%s\n' "$path" >>"$GH_LOG"
    case "$path" in
      */git/matching-refs/tags/*)
        [[ -z "${RC_LIST_FAILS:-}" ]] || { echo "gh: dial tcp: lookup api.github.com" >&2; return 1; }
        local ref refs=()
        for ref in ${RC_REFS:-}; do refs+=("$(printf '{"ref":"refs/tags/%s"}' "$ref")"); done
        (IFS=,; printf '[%s]\n' "${refs[*]}") | jq -r "${@: -1}" ;;
      */compare/*)
        [[ -z "${COMPARE_FAILS:-}" ]] || { echo "gh: No common ancestor (HTTP 404)" >&2; return 1; }
        local c_status c_ahead c_behind
        read -r c_status c_ahead c_behind <<<"${COMPARE:-identical 0 0}"
        printf '{"status":"%s","ahead_by":%s,"behind_by":%s}\n' "$c_status" "$c_ahead" "$c_behind" | jq -r "${@: -1}" ;;
      *) echo "unexpected gh call: $*" >&2; return 1 ;;
    esac
  }
}

SHA="898ff52e596d2335922f274bdb97aa0de92b03b4"

@test "require_rc_commit: a prerelease is not checked" {
  rc_stub
  for v in v4.12.3-rc.3 v4.12.3-alpha.1 v4.13.0-next.internal.1; do
    run require_rc_commit loft-sh/loft-enterprise "$v" "$SHA"
    [ "$status" -eq 0 ]
  done
  [ ! -s "$GH_LOG" ]
}

@test "require_rc_commit: passes when the commit is the newest rc's" {
  rc_stub
  RC_REFS="v4.12.3-rc.1 v4.12.3-rc.2" COMPARE="identical 0 0"
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::${SHA} is the commit v4.12.3-rc.2 was cut from"* ]]
  # The tag is all the guard reads, so it says nothing about the rc's tests.
  [[ "$output" != *"tested"* ]]
  grep -qx "repos/loft-sh/loft-enterprise/compare/refs/tags/v4.12.3-rc.2...${SHA}?per_page=1" "$GH_LOG"
}

@test "require_rc_commit: refuses commits that landed after the newest rc" {
  rc_stub
  RC_REFS="v4.12.3-rc.1 v4.12.3-rc.2" COMPARE="ahead 5 0"
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to cut v4.12.3 in loft-sh/loft-enterprise: the commit to release (${SHA}) is 5 commit(s) past v4.12.3-rc.2, the last rc"* ]]
  [[ "$output" == *"Cut v4.12.3-rc.3, then cut v4.12.3 once it passes"* ]]
  [[ "$output" == *"This run created no tag and dispatched no release build in loft-sh/loft-enterprise."* ]]
  [[ "$output" == *"https://github.com/loft-sh/loft-enterprise/compare/v4.12.3-rc.2...${SHA}"* ]]
}

@test "require_rc_commit: the newest rc is the highest number, not the last listed" {
  rc_stub
  RC_REFS="v4.12.0-rc.10 v4.12.0-rc.12 v4.12.0-rc.2 v4.12.0-rc.9" COMPARE="ahead 1 0"
  run require_rc_commit loft-sh/loft-enterprise v4.12.0 "$SHA"
  [ "$status" -eq 1 ]
  grep -q "compare/refs/tags/v4.12.0-rc.12\.\.\." "$GH_LOG"
  [[ "$output" == *"Cut v4.12.0-rc.13"* ]]
}

@test "require_rc_commit: tags that only share the prefix are not rcs of this version" {
  rc_stub
  RC_REFS="v4.12.3-rc.1 v4.12.3-rc.7-hotfix v4.12.3-rc.08 v4.12.3-rc."
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 0 ]
  grep -q "compare/refs/tags/v4.12.3-rc.1\.\.\." "$GH_LOG"
}

@test "require_rc_commit: refuses a stable with no rc" {
  rc_stub
  RC_REFS=""
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to cut v4.12.3 in loft-sh/loft-enterprise: v4.12.3 has no rc there"* ]]
  [[ "$output" == *"Cut v4.12.3-rc.1, then cut v4.12.3 once it passes"* ]]
  ! grep -q compare "$GH_LOG"
}

@test "require_rc_commit: refuses a commit behind or diverged from the rc" {
  rc_stub
  RC_REFS="v4.12.0-rc.12"
  COMPARE="behind 0 11"
  run require_rc_commit loft-sh/loft-enterprise v4.12.0 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is 11 commit(s) behind v4.12.0-rc.12"* ]]
  COMPARE="diverged 2 3"
  run require_rc_commit loft-sh/loft-enterprise v4.12.0 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"diverged from v4.12.0-rc.12 (2 ahead, 3 behind)"* ]]
}

@test "require_rc_commit: allowed excuses commits on top of the rc and nothing else" {
  rc_stub
  RC_REFS="v0.36.3-rc.1"
  COMPARE="ahead 1 0"
  run require_rc_commit loft-sh/vcluster-pro v0.36.3 "$SHA" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 commit(s) past v0.36.3-rc.1, within the 1 allowed on top of the rc"* ]]
  COMPARE="identical 0 0"
  run require_rc_commit loft-sh/vcluster-pro v0.36.3 "$SHA" 1
  [ "$status" -eq 0 ]
  COMPARE="ahead 2 0"
  run require_rc_commit loft-sh/vcluster-pro v0.36.3 "$SHA" 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 commit(s) past v0.36.3-rc.1 (at most 1 allowed"* ]]
  COMPARE="diverged 1 1"
  run require_rc_commit loft-sh/vcluster-pro v0.36.3 "$SHA" 1
  [ "$status" -eq 1 ]
}

@test "require_rc_commit: a failed read refuses rather than passing" {
  rc_stub
  RC_LIST_FAILS=1
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not list the v4.12.3-rc.N tags in loft-sh/loft-enterprise"* ]]
  [[ "$output" == *"gh said: gh: dial tcp"* ]]
  RC_LIST_FAILS="" RC_REFS="v4.12.3-rc.2" COMPARE_FAILS=1
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not compare ${SHA} with v4.12.3-rc.2"* ]]
}

@test "require_rc_commit: an answer it cannot read refuses" {
  rc_stub
  RC_REFS="v4.12.3-rc.2"
  COMPARE="null null null"
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected comparison"* ]]
  COMPARE="weird 0 0"
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected comparison status 'weird'"* ]]
}

@test "require_rc_commit: on a resume the refusal names the tag, which stays where it is" {
  # An rc is cut at the branch head, so once the branch has moved on, no rc can
  # land on an existing tag: asking for another one would loop.
  rc_stub
  RC_REFS="v4.12.3-rc.2 v4.12.3-rc.3" COMPARE="behind 0 4"
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA" 0 resume
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to resume v4.12.3 in loft-sh/loft-enterprise: tag v4.12.3 (${SHA}) is 4 commit(s) behind v4.12.3-rc.3, the last rc"* ]]
  [[ "$output" == *"Another rc alone will not fix this here"* ]]
  [[ "$output" == *"This run created no tag and dispatched no release build in loft-sh/loft-enterprise."* ]]
  [[ "$output" != *"Cut v4.12.3-rc.4"* ]]
  [[ "$output" != *"Cut v4.12.3-rc."* ]]
  RC_REFS=""
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA" 0 resume
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to resume v4.12.3 in loft-sh/loft-enterprise: v4.12.3 has no rc there"* ]]
  [[ "$output" != *"Cut v4.12.3-rc.1"* ]]
}

@test "require_rc_commit: a commit behind the rc links the commits it lacks" {
  # compare/<rc>...<sha> lists nothing when sha is behind, so that link would be empty.
  rc_stub
  RC_REFS="v4.12.3-rc.3" COMPARE="behind 0 4"
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"https://github.com/loft-sh/loft-enterprise/compare/${SHA}...v4.12.3-rc.3"* ]]
}

@test "is_stable_version: only a plain vX.Y.Z is held to an rc" {
  run is_stable_version v4.12.3
  [ "$status" -eq 0 ]
  for v in v4.12.3-rc.1 v4.13.0-next.internal.1 4.12.3 v4.12; do
    run is_stable_version "$v"
    [ "$status" -ne 0 ]
  done
}

@test "newest_rc: the highest rc number, -1 for none, and a failed listing is not read as none" {
  rc_stub
  local n rc
  RC_REFS="v4.12.0-rc.10 v4.12.0-rc.12 v4.12.0-rc.2 v4.12.0-rc.13-hotfix"
  newest_rc n loft-sh/loft-enterprise v4.12.0
  [ "$n" -eq 12 ]
  RC_REFS=""
  newest_rc n loft-sh/loft-enterprise v4.12.0
  [ "$n" -eq -1 ]
  RC_LIST_FAILS=1
  rc=0; newest_rc n loft-sh/loft-enterprise v4.12.0 || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$NEWEST_RC_ERR" == *"dial tcp"* ]]
}

@test "require_rc_commit: the resume refusal points at the README's recovery steps" {
  # The two actions name that section differently, so it is not named here.
  rc_stub
  RC_REFS="v4.12.3-rc.2" COMPARE="ahead 1 0"
  run require_rc_commit loft-sh/loft-enterprise v4.12.3 "$SHA" 0 resume
  [ "$status" -eq 1 ]
  [[ "$output" == *"read the recovery steps in this action's README before changing any tag"* ]]
  [[ "$output" != *"README on re-running a cut"* ]]
}

@test "require_rc_commit: past an allowance the refusal does not send the operator to another rc" {
  # Only a legacy pro check passes an allowance, and it is refused only once the
  # bump is on the branch, where a bare "cut the next rc" leads to a stable
  # re-cut that skips the merged bump.
  rc_stub
  RC_REFS="v0.36.3-rc.1" COMPARE="ahead 2 0"
  run require_rc_commit loft-sh/vcluster-pro v0.36.3 "$SHA" 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 commit(s) past v0.36.3-rc.1 (at most 1 allowed)"* ]]
  [[ "$output" != *"Cut v0.36.3-rc.2"* ]]
  [[ "$output" == *"Another rc alone will not fix this here"* ]]
  [[ "$output" == *"read the recovery steps in this action's README"* ]]
  # Without an allowance the plain advice stands.
  run require_rc_commit loft-sh/vcluster-pro v0.36.3 "$SHA" 0
  [ "$status" -eq 1 ]
  [[ "$output" != *"Another rc alone"* ]]
  [[ "$output" == *"then cut v0.36.3 once it passes"* ]]
}

@test "require_rc_commit: a partial cut is not sent to another rc, and a failed read says to re-run" {
  rc_stub
  RC_REFS="v0.36.3-rc.1" COMPARE="ahead 1 0"
  run require_rc_commit loft-sh/vcluster-pro v0.36.3 "$SHA" 0 partial
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to cut v0.36.3 in loft-sh/vcluster-pro"* ]]
  [[ "$output" == *"Another rc alone will not fix this here"* ]]
  [[ "$output" != *"Cut v0.36.3-rc.2"* ]]
  RC_LIST_FAILS=1
  run require_rc_commit loft-sh/vcluster-pro v0.36.3 "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Re-run the cut once GitHub answers"* ]]
  [[ "$output" != *"README"* ]]
}

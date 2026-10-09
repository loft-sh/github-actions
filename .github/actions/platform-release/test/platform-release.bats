#!/usr/bin/env bats
# Tests for platform-release.sh
#
# The routing helpers (normalize_version / validate_version / parse_major_minor /
# derive_line / classify_suffix / is_feature_branch / resolve_target) are pure and
# network-free. resolve_head / check_release_state / create_tag / dispatch and
# main are exercised with a configurable `gh` stub on PATH, so no real API call is
# made.

# require_dispatchable reads workflows with the real yq, so a machine with the
# python yq wrapper first on PATH would fail most of this suite for no clear
# reason. Stop once, up front, instead.
setup_file() {
  if ! (source "${BATS_TEST_DIRNAME}/../src/platform-release.sh" && require_yq); then
    echo "these tests need the same yq the action does (see the error above)" >&2
    return 1
  fi
}

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/platform-release.sh"
  # Read when the script is sourced, so the post-dispatch wait does not sleep.
  export PLATFORM_DISPATCH_VISIBLE_ATTEMPTS=3
  export PLATFORM_DISPATCH_VISIBLE_SLEEP_SECONDS=0
  # Also read when sourced. A CI step must not pick the README link.
  unset GITHUB_ACTION_REPOSITORY GITHUB_ACTION_REF
  source "$SCRIPT"

  STUB_DIR="$(mktemp -d)"
  PATH="${STUB_DIR}:${PATH}"
  # The commit an existing tag points at, and the tag object of an annotated one.
  export STUB_TAG_COMMIT="1111111111111111111111111111111111111111"
  export STUB_TAG_OBJECT="2222222222222222222222222222222222222222"
  export STUB_TAG_OBJECT2="4444444444444444444444444444444444444444"
  install_gh_stub
}

teardown() {
  rm -rf "$STUB_DIR"
}

# A single configurable `gh` stub. It reads which branches/releases/tags "exist"
# from env set per-test:
#   GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
#   GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
#   GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
#   GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"   (draft releases)
# Anything not listed 404s / is absent. POST refs, refs/heads sha lookups and
# `workflow run` succeed (only reached in non-dry-run tests). GH_STUB_TRANSIENT /
# GH_STUB_UNEXPECTED simulate API failures on every probe; GH_STUB_TRANSIENT_TAGS
# scopes a transient failure to the double-cut probes only (branch check still
# passes), to exercise check_release_state's transient handling in isolation.
install_gh_stub() {
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
set -u
sub="$1"; shift || true
# Where the stub keeps what earlier calls changed: the tag it created and the
# runs it queued.
state_dir="$(dirname "$0")"

contains() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

if [[ "$sub" == "api" ]]; then
  # Skip flags to find the path: `gh api -X POST <path> -f k=v` puts `-X` in $1.
  # The whole list is scanned because --jq follows the path, and its filter is
  # applied below.
  all_args="$*"
  path=""
  jq_filter=""
  method="GET"
  include=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jq) jq_filter="${2:-}"; shift 2 || true ;;
      -X) method="${2:-}"; shift 2 || true ;;
      -i) include=1; shift ;;
      -f | -F | -H) shift 2 || true ;;
      -*) shift ;;
      *) [[ -z "$path" ]] && path="$1"; shift ;;
    esac
  done
  # emit_status <present:0|1> <scope> - print an HTTP status line and exit like
  # real gh. Real gh prints the status line to stdout for 200 AND 404, but exits
  # non-zero on 404. GH_STUB_TRANSIENT=1 simulates a network/auth failure (no
  # status line, non-zero exit) on every probe. GH_STUB_TRANSIENT_TAGS=1 scopes
  # that same failure to the double-cut probes only (scope=tags), so a test can
  # let the branch check pass and still exercise the guard's transient handling.
  # GH_STUB_UNEXPECTED=1 simulates an unexpected status (403/500) that is neither
  # 200 nor 404 - it must abort, not fall back.
  emit_status() {
    fail_if_simulated "$2"
    if [[ "$1" == "0" ]]; then echo "HTTP/2.0 200 OK"; exit 0; else echo "HTTP/2.0 404 Not Found"; exit 1; fi
  }
  # fail_if_simulated <scope> - exit the way gh does on the failure the flags
  # above ask for, or return so the caller answers normally.
  fail_if_simulated() {
    # Real gh writes the cause to stderr and prints no status line. Emitted here
    # so a test can prove the probes surface it instead of swallowing it.
    # The repo probe runs first on every cut, so it has its own flag; otherwise
    # every transient test would stop there and never reach the probe it names.
    if [[ "$1" == "repo" ]]; then
      if [[ "${GH_STUB_TRANSIENT_REPO:-}" == "1" ]]; then echo "gh: dial tcp: lookup api.github.com" >&2; exit 1; fi
      return 0
    fi
    if [[ "${GH_STUB_TRANSIENT:-}" == "1" ]]; then
      if [[ "${GH_STUB_TRANSIENT_MULTILINE:-}" == "1" ]]; then
        # A response body carrying a newline plus a forged workflow command.
        printf 'gh: dial tcp\n::error::FORGED\n' >&2
      else
        echo "gh: dial tcp: lookup api.github.com" >&2
      fi
      exit 1
    fi
    if [[ "$1" == "tags" && "${GH_STUB_TRANSIENT_TAGS:-}" == "1" ]]; then echo "gh: dial tcp: lookup api.github.com" >&2; exit 1; fi
    # Headers on stdout, gh's reason on stderr - the live shape of an SSO/scope
    # rejection, which is what makes the reason worth surfacing at all.
    if [[ "${GH_STUB_UNEXPECTED:-}" == "1" ]]; then
      echo "HTTP/2.0 403 Forbidden"
      echo "gh: Resource protected by organization SAML enforcement." >&2
      exit 1
    fi
  }
  # respond <200|404> <json> - answer a body read the way real gh does. With -i
  # that is the headers, a blank line, then the body through the caller's --jq;
  # a 404 prints the headers and raw body, puts gh's reason on stderr and exits
  # non-zero.
  respond() {
    if [[ "$1" == "200" ]]; then
      ((include)) && printf 'HTTP/2.0 200 OK\nContent-Type: application/json\n\n'
      if [[ -n "$jq_filter" ]]; then printf '%s\n' "$2" | jq -r "$jq_filter"; else printf '%s\n' "$2"; fi
      exit $?
    fi
    ((include)) && printf 'HTTP/2.0 404 Not Found\nContent-Type: application/json\n\n{"message":"Not Found"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  }
  case "$path" in
    repos/*/branches/*)
      rest="${path#repos/}"; repo="${rest%%/branches/*}"; branch="${rest##*/branches/}"
      contains "${GH_STUB_BRANCHES:-}" "${repo}:${branch}" && emit_status 0 branches || emit_status 1 branches ;;
    repos/*/releases/tags/*)
      [[ -n "${GH_STUB_CONTENTS_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_CONTENTS_LOG"
      rest="${path#repos/}"; repo="${rest%%/releases/tags/*}"; tag="${rest##*/releases/tags/}"
      contains "${GH_STUB_RELEASES:-}" "${repo}:${tag}" && emit_status 0 tags || emit_status 1 tags ;;
    repos/*/releases\?*)
      # The release list the double-cut guard reads. GH_STUB_DRAFTS names draft
      # releases the same way GH_STUB_RELEASES names published ones. Served in
      # pages of GH_STUB_PAGE_SIZE (default 2), published first, and without
      # --paginate only the first page comes back, as with real gh. The
      # caller's --jq runs over each page, as gh applies it. Published releases
      # get ids from 101, drafts from GH_STUB_DRAFT_ID_BASE+1 (default 201), in
      # the order listed. A draft entry
      # ending in @shipped was published once and turned back into a draft
      # when its tag was deleted, so it keeps a published_at.
      # GH_STUB_RELEASES_REPEAT=1 lists the last release again, as a list that
      # shifts between pages does, and =published lists it again as published.
      [[ -n "${GH_STUB_CONTENTS_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_CONTENTS_LOG"
      if [[ "${GH_STUB_TRANSIENT:-}${GH_STUB_TRANSIENT_DRAFTS:-}" == *1* ]]; then
        echo "gh: dial tcp: lookup api.github.com" >&2; exit 1
      fi
      rest="${path#repos/}"; repo="${rest%%/releases\?*}"
      releases=()
      rid=100
      for entry in ${GH_STUB_RELEASES:-}; do
        rid=$((rid + 1))
        [[ "${entry%%:*}" == "$repo" ]] && releases+=("$(printf '{"id":%s,"tag_name":"%s","draft":false}' "$rid" "${entry#*:}")")
      done
      rid="${GH_STUB_DRAFT_ID_BASE:-200}"
      for entry in ${GH_STUB_DRAFTS:-}; do
        rid=$((rid + 1))
        d_published=null
        [[ "$entry" == *@shipped ]] && d_published='"2026-01-01T00:00:00Z"'
        entry="${entry%@shipped}"
        [[ "${entry%%:*}" == "$repo" ]] && releases+=("$(printf '{"id":%s,"tag_name":"%s","draft":true,"published_at":%s}' "$rid" "${entry#*:}" "$d_published")")
      done
      [[ "${GH_STUB_RELEASES_REPEAT:-}" == "1" ]] && releases+=("${releases[-1]}")
      [[ "${GH_STUB_RELEASES_REPEAT:-}" == "published" ]] && releases+=("${releases[-1]/\"draft\":true/\"draft\":false}")
      size="${GH_STUB_PAGE_SIZE:-2}"
      for ((i = 0; i == 0 || i < ${#releases[@]}; i += size)); do
        page="$(IFS=,; printf '[%s]' "${releases[*]:i:size}")"
        printf '%s\n' "$page" | jq -r "${jq_filter:-.}" || exit $?
        [[ "$all_args" == *--paginate* ]] || break
      done
      exit 0 ;;
    repos/*/git/ref/tags/*)
      # Singular endpoint: exact match, 404 otherwise (mirrors the real API).
      # An existing tag points at GH_STUB_TAG_SHA. GH_STUB_TAG_ANNOTATED=1 makes
      # it an annotated tag, whose ref names a tag object that git/tags/ peels.
      # GH_STUB_TAG_NO_SHA=1 answers with a ref body that has no .object.sha.
      fail_if_simulated tags
      [[ -n "${GH_STUB_CONTENTS_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_CONTENTS_LOG"
      rest="${path#repos/}"; repo="${rest%%/git/ref/tags/*}"; tag="${rest##*/git/ref/tags/}"
      contains "${GH_STUB_TAGS:-}" "${repo}:${tag}" || respond 404
      if [[ "${GH_STUB_TAG_NO_SHA:-}" == "1" ]]; then
        respond 200 '{"object":{}}'
      elif [[ "${GH_STUB_TAG_ANNOTATED:-}" == "1" ]]; then
        respond 200 '{"object":{"sha":"'"${STUB_TAG_OBJECT}"'","type":"tag"}}'
      fi
      respond 200 '{"object":{"sha":"'"${GH_STUB_TAG_SHA:-$STUB_TAG_COMMIT}"'","type":"commit"}}' ;;
    repos/*/git/tags/*)
      # Peels a tag object. GH_STUB_TAG_NESTED=1 makes STUB_TAG_OBJECT point at a
      # second tag object (STUB_TAG_OBJECT2) before the commit.
      # GH_STUB_TAG_PEELS_TO=<type> makes the last object that type, not a commit.
      [[ -n "${GH_STUB_CONTENTS_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_CONTENTS_LOG"
      if [[ "${GH_STUB_TAG_NESTED:-}" == "1" && "${path##*/}" == "$STUB_TAG_OBJECT" ]]; then
        respond 200 '{"object":{"sha":"'"${STUB_TAG_OBJECT2}"'","type":"tag"}}'
      fi
      respond 200 '{"object":{"sha":"'"${GH_STUB_TAG_SHA:-$STUB_TAG_COMMIT}"'","type":"'"${GH_STUB_TAG_PEELS_TO:-commit}"'"}}' ;;
    repos/*/actions/runs/*/attempts/*)
      # An earlier attempt of a re-run, from the fourth field of its
      # GH_STUB_RUNS entry, or its latest attempt, from the third field unless
      # GH_STUB_LATEST_ATTEMPT names another conclusion. GH_STUB_ATTEMPTS_FAIL=1
      # answers 404, =transient fails with no HTTP status and =403 with a 403,
      # saying GH_STUB_ATTEMPTS_ERR if set.
      [[ -n "${GH_STUB_CONTENTS_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_CONTENTS_LOG"
      [[ "${GH_STUB_ATTEMPTS_FAIL:-}" == "1" ]] && respond 404
      if [[ "${GH_STUB_ATTEMPTS_FAIL:-}" == "transient" ]]; then
        echo "${GH_STUB_ATTEMPTS_ERR:-gh: dial tcp: lookup api.github.com}" >&2; exit 1
      fi
      if [[ "${GH_STUB_ATTEMPTS_FAIL:-}" == "403" ]]; then
        ((include)) && printf 'HTTP/2.0 403 Forbidden\nContent-Type: application/json\n\n{"message":"Forbidden"}'
        echo "${GH_STUB_ATTEMPTS_ERR:-gh: Forbidden (HTTP 403)}" >&2; exit 1
      fi
      rest="${path#*/actions/runs/}"; r_id="${rest%%/*}"; r_k="${path##*/}"
      read -ra r_entries <<<"${GH_STUB_RUNS:-}"
      IFS=: read -r _ _ r_last r_earlier <<<"${r_entries[r_id - ${GH_STUB_RUN_ID_BASE:-0} - 1]:-}"
      r_latest=1
      [[ -n "$r_earlier" ]] && r_latest=$(( $(tr -cd , <<<"$r_earlier" | wc -c) + 2 ))
      if ((r_k == r_latest)); then
        r_last="${GH_STUB_LATEST_ATTEMPT:-$r_last}"
        [[ "$r_last" == "null" ]] && respond 200 '{"conclusion":null}'
        respond 200 "$(printf '{"conclusion":"%s"}' "$r_last")"
      fi
      IFS=, read -ra r_earlier <<<"$r_earlier"
      [[ -n "${r_earlier[r_k - 1]:-}" ]] || respond 404
      respond 200 "$(printf '{"conclusion":"%s"}' "${r_earlier[r_k - 1]}")" ;;
    repos/*/actions/workflows/*/runs\?*)
      # The runs the resume check and the post-dispatch wait read. GH_STUB_RUNS
      # lists them as <head_sha>:<status>:<conclusion>, and every dispatch the
      # stub accepts adds a queued run of the tagged commit. GitHub records
      # them under head_branch GH_STUB_RUNS_HEAD_BRANCH (short: the tag name,
      # the default; full: refs/tags/<tag>), and only a branch= query for that
      # spelling lists them. GH_STUB_RUNS_FAILS=1 fails the read,
      # GH_STUB_RUNS_BAD_SHAPE=1 answers 200 with an error-shaped body. Runs get
      # ids from GH_STUB_RUN_ID_BASE+1 (default 1). An entry may add a fourth
      # field, the conclusions of the run's earlier attempts, comma-separated,
      # which makes it a re-run whose attempts/<n> answers with them.
      # GH_STUB_DISPATCH_VISIBLE_AFTER=<n> holds the dispatched run back until
      # the n-th poll after the dispatch. A poll reads both spellings, short
      # first, so the short read counts the polls (into dispatch_polls).
      [[ -n "${GH_STUB_CONTENTS_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_CONTENTS_LOG"
      if [[ "${GH_STUB_RUNS_FAILS:-}" == "1" ]]; then
        echo "gh: dial tcp: lookup api.github.com" >&2; exit 1
      fi
      if [[ "${GH_STUB_RUNS_BAD_SHAPE:-}" == "1" ]]; then
        printf '{"message":"Server Error"}\n' | jq -r "${jq_filter:-.}"; exit $?
      fi
      query_branch="${path#*branch=}"; query_branch="${query_branch%%&*}"
      case "${GH_STUB_RUNS_HEAD_BRANCH:-short}" in
        full) [[ "$query_branch" == refs/tags/* ]] ;;
        *) [[ "$query_branch" != refs/tags/* ]] ;;
      esac
      listed=$?
      if [[ -f "${state_dir}/dispatch_pending" && "$query_branch" != refs/tags/* ]]; then
        polls=$(( $(cat "${state_dir}/dispatch_polls" 2>/dev/null || echo 0) + 1 ))
        echo "$polls" >"${state_dir}/dispatch_polls"
        if ((polls >= GH_STUB_DISPATCH_VISIBLE_AFTER)); then
          cat "${state_dir}/dispatch_pending" >>"${state_dir}/dispatched_runs"
          rm "${state_dir}/dispatch_pending"
        fi
      fi
      runs=()
      n=0
      entries="${GH_STUB_RUNS:-}"
      [[ -f "${state_dir}/dispatched_runs" ]] && entries+=" $(cat "${state_dir}/dispatched_runs")"
      for entry in $entries; do
        n=$((n + 1))
        ((listed == 0)) || continue
        IFS=: read -r r_sha r_status r_conclusion r_earlier <<<"$entry"
        if [[ "$r_conclusion" == "null" ]]; then r_conclusion=null; else r_conclusion="\"${r_conclusion}\""; fi
        r_attempt=1
        [[ -n "$r_earlier" ]] && r_attempt=$(( $(tr -cd , <<<"$r_earlier" | wc -c) + 2 ))
        runs+=("$(printf '{"id":%s,"run_attempt":%s,"head_sha":"%s","status":"%s","conclusion":%s}' "$((${GH_STUB_RUN_ID_BASE:-0} + n))" "$r_attempt" "$r_sha" "$r_status" "$r_conclusion")")
      done
      # Served in pages of GH_STUB_RUNS_PAGE_SIZE (default: all on one), and
      # without --paginate only the first page comes back, as with real gh.
      size="${GH_STUB_RUNS_PAGE_SIZE:-${#runs[@]}}"
      ((size > 0)) || size=1
      for ((i = 0; i == 0 || i < ${#runs[@]}; i += size)); do
        printf '{"workflow_runs":[%s]}\n' "$(IFS=,; printf '%s' "${runs[*]:i:size}")" | jq -r "${jq_filter:-.}" || exit $?
        [[ "$all_args" == *--paginate* ]] || break
      done
      exit 0 ;;
    repos/*/compare/*)
      # The resume's check that the tag is on the target branch.
      # GH_STUB_COMPARE_STATUS is the answer (default behind: the tag commit is
      # an ancestor of the branch head). GH_STUB_COMPARE_LOG records the path.
      [[ -n "${GH_STUB_COMPARE_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_COMPARE_LOG"
      respond 200 "$(printf '{"status":"%s"}' "${GH_STUB_COMPARE_STATUS:-behind}")" ;;
    repos/*/git/refs/tags/*)
      # The action never deletes a tag. Logged so a test can prove it.
      if [[ "$method" == "DELETE" ]]; then
        [[ -n "${GH_STUB_CALL_LOG:-}" ]] && printf '%s\n' "$all_args" >>"$GH_STUB_CALL_LOG"
        exit 0
      fi
      # Plural endpoint: prefix match (mirrors the real API). Kept so a regression
      # from the singular exact-match endpoint trips the false-double-cut test.
      rest="${path#repos/}"; repo="${rest%%/git/refs/tags/*}"; tag="${rest##*/git/refs/tags/}"
      for entry in ${GH_STUB_TAGS:-}; do
        [[ "${entry%%:*}" == "$repo" && "${entry#*:}" == "${tag}"* ]] && emit_status 0 tags
      done
      emit_status 1 tags ;;
    repos/*/git/ref/heads/*)
      # Singular endpoint: exact match only, mirroring the real API. GH_STUB_BRANCHES
      # gates it so a branch deleted mid-cut reads as a clean 404, not a sha.
      # GH_STUB_HEAD_MISSING=1 makes only this probe 404, simulating a branch
      # deleted after an earlier probe saw it. GH_STUB_HEAD_NO_SHA=1 answers 200
      # with a ref body that has no .object.sha. GH_STUB_TRANSIENT_HEADS=1 fails
      # only this read the way an unreachable API does, so every earlier probe
      # still answers.
      fail_if_simulated branches
      if [[ "${GH_STUB_TRANSIENT_HEADS:-}" == "1" ]]; then echo "gh: dial tcp: lookup api.github.com" >&2; exit 1; fi
      [[ "${GH_STUB_HEAD_MISSING:-}" == "1" ]] && respond 404
      rest="${path#repos/}"; repo="${rest%%/git/ref/heads/*}"; branch="${rest##*/git/ref/heads/}"
      contains "${GH_STUB_BRANCHES:-}" "${repo}:${branch}" || respond 404
      # Real API shape, run through the caller's own --jq, so the filter the
      # script sends is what the tests exercise. The sha is derived from the
      # branch so the routing tests can see which branch was chosen.
      if [[ "${GH_STUB_HEAD_NO_SHA:-}" == "1" ]]; then
        body='{"object":{}}'
      else
        body="$(printf '{"object":{"sha":"head-%s"}}' "$branch")"
      fi
      respond 200 "$body" ;;
    repos/*/git/refs/heads/*)
      # Plural endpoint: falls back to an array of prefix matches when the exact
      # ref is gone, so `--jq .object.sha` errors out. Kept so a regression from
      # the singular form is visible rather than silently equivalent.
      echo "jq: error: Cannot index array with string \"object\"" >&2; exit 1 ;;
    repos/*/git/refs)
      # Tag creation. Recorded so the live-cut test can assert the ref and sha
      # actually sent, not just create_tag's own echo.
      [[ -n "${GH_STUB_CALL_LOG:-}" ]] && printf '%s\n' "$all_args" >>"$GH_STUB_CALL_LOG"
      # A protected-ref rule or a concurrent cut rejects the create.
      if [[ "${GH_STUB_TAG_POST_FAILS:-}" == "1" ]]; then
        echo "gh: Reference already exists (HTTP 422)" >&2; exit 1
      fi
      # Remembered so a later dispatch queues a run of the commit just tagged.
      [[ "$all_args" =~ sha=([^ ]+) ]] && printf '%s' "${BASH_REMATCH[1]}" >"${state_dir}/posted_sha"
      exit 0 ;;
    repos/*/contents/.github/workflows/*)
      # Read by require_dispatchable. The default is the converted
      # (dispatcher-era) shape; the flags reproduce the two pre-conversion shapes
      # and an unreadable file.
      # Logged separately from GH_STUB_CALL_LOG so the tests that assert NOTHING
      # was mutated can still expect that log to be empty.
      [[ -n "${GH_STUB_CONTENTS_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_CONTENTS_LOG"
      # A whole workflow, for the cases that need no comment beyond their test.
      if [[ -n "${GH_STUB_WF_BODY:-}" ]]; then
        printf '%s\n' "$GH_STUB_WF_BODY"; exit 0
      fi
      if [[ "${GH_STUB_WF_UNREADABLE:-}" == "1" ]]; then
        echo "gh: Not Found (HTTP 404)" >&2; exit 1
      fi
      if [[ "${GH_STUB_WF_NO_DISPATCH:-}" == "1" ]]; then
        printf 'on:\n  release:\n    types:\n      - created\n'; exit 0
      fi
      if [[ "${GH_STUB_WF_NO_TRIGGERED_BY:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n'; exit 0
      fi
      # A line whose banner takes the branch from the cut. Required with no
      # default, the strictest shape, which the cut must still satisfy.
      if [[ "${GH_STUB_WF_SOURCE_BRANCH:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        type: string\n      source_branch:\n        required: true\n%b%b' \
          "${GH_STUB_WF_SOURCE_BRANCH_TYPE:+        type: ${GH_STUB_WF_SOURCE_BRANCH_TYPE}\n}" \
          "${GH_STUB_WF_SOURCE_BRANCH_DEFAULT:+        default: ${GH_STUB_WF_SOURCE_BRANCH_DEFAULT}\n}"; exit 0
      fi
      if [[ -n "${GH_STUB_WF_TRIGGERED_BY_TYPE:-}" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        type: %s\n' "$GH_STUB_WF_TRIGGERED_BY_TYPE"; exit 0
      fi
      if [[ -n "${GH_STUB_WF_SOURCE_BRANCH_TYPE:-}" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        type: string\n      source_branch:\n        type: %s\n' "$GH_STUB_WF_SOURCE_BRANCH_TYPE"; exit 0
      fi
      # The declaration is gone but the job plumbing that PASSES it remains - the
      # shape that satisfied an unscoped grep and then 422'd after the tag.
      if [[ "${GH_STUB_WF_TRIGGERED_BY_IN_JOB:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\njobs:\n  build:\n    with:\n      triggered_by: ${{ inputs.triggered_by }}\n'; exit 0
      fi
      # The bare scalar trigger form, legal and natural for a dispatch-only
      # workflow that declares no inputs.
      if [[ "${GH_STUB_WF_SCALAR_ON:-}" == "1" ]]; then
        printf 'on: workflow_dispatch\njobs: {}\n'; exit 0
      fi
      # The block-sequence trigger form, indented under the key.
      if [[ "${GH_STUB_WF_SEQUENCE_ON:-}" == "1" ]]; then
        printf 'on:\n  - workflow_call\n  - workflow_dispatch\n'; exit 0
      fi
      # The same sequence at the parent's indentation, which is legal YAML.
      if [[ "${GH_STUB_WF_SEQUENCE_FLUSH:-}" == "1" ]]; then
        printf 'name: Release\non:\n- workflow_call\n- workflow_dispatch\njobs: {}\n'; exit 0
      fi
      # A trailing comment on the trigger line itself.
      if [[ "${GH_STUB_WF_TRAILING_COMMENT:-}" == "1" ]]; then
        printf 'on:\n  - workflow_call\n  - workflow_dispatch  # manual cut only\n'; exit 0
      fi
      if [[ "${GH_STUB_WF_SCALAR_TRAILING_COMMENT:-}" == "1" ]]; then
        printf 'on: workflow_dispatch  # manual cut only\njobs: {}\n'; exit 0
      fi
      # Parked during a code freeze: the trigger is present as TEXT but the
      # workflow is not dispatchable.
      if [[ "${GH_STUB_WF_COMMENTED_OUT:-}" == "1" ]]; then
        printf 'on:\n  push:\n    tags: ["v*"]\n  # workflow_dispatch:  parked during the freeze\n'; exit 0
      fi
      # The token as part of a VALUE rather than the trigger key - no comment
      # involved, so only the anchoring rejects it.
      if [[ "${GH_STUB_WF_TOKEN_IN_VALUE:-}" == "1" ]]; then
        printf 'on:\n  repository_dispatch:\n    types: [workflow_dispatch-relay]\n'; exit 0
      fi
      # A column-0 comment mentioning the trigger. It does not end the on: block,
      # so an unfiltered block would count it.
      if [[ "${GH_STUB_WF_COMMENT_MENTIONS:-}" == "1" ]]; then
        printf 'on:\n  release:\n    types: [created]\n# note: workflow_dispatch runs are serialized\nconcurrency:\n  group: x\n'; exit 0
      fi
      # The declaration lives under workflow_call, for the workflow's own
      # callers, and NOT under workflow_dispatch - which is the contract
      # `gh workflow run` is held to. An on:-wide grep read the first as the
      # second and passed a line that then 422'd after the tag existed.
      if [[ "${GH_STUB_WF_TRIGGERED_BY_IN_CALL:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        required: false\n  workflow_call:\n    inputs:\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # Both declared under workflow_dispatch: the callable-AND-dispatchable
      # shape must still pass, or the fix above would block every line that has
      # a workflow_call sibling.
      if [[ "${GH_STUB_WF_TRIGGERED_BY_IN_BOTH:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        type: string\n  workflow_call:\n    inputs:\n      triggered_by:\n        type: string\njobs: {}\n'; exit 0
      fi
      # An input the dispatch does not pass, required with no default: the API
      # answers "Required input not provided" - after the tag exists.
      if [[ "${GH_STUB_WF_REQUIRED_NO_DEFAULT:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        description: version to build\n        required: true\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # A tab is legal separation after the colon, in the key line and the value.
      if [[ "${GH_STUB_WF_REQUIRED_TAB:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\t\n    inputs:\n      version:\n        required:\ttrue\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # workflow_call only, with a nested key that happens to be named
      # workflow_dispatch. Not a trigger, so not dispatchable.
      if [[ "${GH_STUB_WF_NESTED_DISPATCH_KEY:-}" == "1" ]]; then
        printf 'on:\n  workflow_call:\n    inputs:\n      workflow_dispatch:\n        type: string\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # An input named with an integer key, which yq does not read as a string.
      if [[ "${GH_STUB_WF_INT_INPUT:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      1:\n        required: true\n'; exit 0
      fi
      # The triggers pulled in with a merge key, which GitHub does not support.
      if [[ "${GH_STUB_WF_MERGE_KEY:-}" == "1" ]]; then
        printf 'x-on: &t\n  workflow_dispatch:\non:\n  <<: *t\n'; exit 0
      fi
      # workflow_dispatch declared twice.
      if [[ "${GH_STUB_WF_DUPLICATE_KEY:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n  pull_request:\n  workflow_dispatch:\n'; exit 0
      fi
      # A quoted "<<" is an ordinary key, not a merge key.
      if [[ "${GH_STUB_WF_QUOTED_MERGE_NAME:-}" == "1" ]]; then
        printf 'x-meta:\n  "<<": literal\non:\n  workflow_dispatch:\n'; exit 0
      fi
      # Not YAML at all: the list never closes.
      if [[ "${GH_STUB_WF_BROKEN_YAML:-}" == "1" ]]; then
        printf 'on: [workflow_dispatch,\n'; exit 0
      fi
      # An input name GitHub would not accept, which cannot be quoted back safely.
      if [[ "${GH_STUB_WF_BAD_INPUT_NAME:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      "a\\nb":\n        required: true\n'; exit 0
      fi
      # The same input WITH a default, which the API fills in - dispatchable, so
      # refusing it would block a legal line.
      if [[ "${GH_STUB_WF_REQUIRED_WITH_DEFAULT:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        required: true\n        default: v0.0.0\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # `required: false` with a trailing comment that mentions true. Stripping
      # the comment before reading the value is what keeps this dispatchable.
      if [[ "${GH_STUB_WF_REQUIRED_IN_COMMENT:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        required: false  # true once the line converts\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # The `on:` block as a flow mapping.
      if [[ "${GH_STUB_WF_FLOW_MAPPING:-}" == "1" ]]; then
        printf 'on: {workflow_dispatch: }\njobs: {}\n'; exit 0
      fi
      # The workflow_dispatch trigger as a flow mapping.
      if [[ "${GH_STUB_WF_DISPATCH_INLINE:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch: {inputs: {triggered_by: {type: string}}}\njobs: {}\n'; exit 0
      fi
      # Only the inputs as a flow mapping.
      if [[ "${GH_STUB_WF_INPUTS_INLINE:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs: {triggered_by: {type: string}}\njobs: {}\n'; exit 0
      fi
      # Flow-style inputs on the workflow_call sibling, which say nothing about
      # the dispatch contract.
      if [[ "${GH_STUB_WF_CALL_INPUTS_INLINE:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        type: string\n  workflow_call:\n    inputs: {triggered_by: {type: string}}\njobs: {}\n'; exit 0
      fi
      # A description whose PROSE starts a line with `default:`. Reading keys out
      # of a block scalar let that satisfy the default check on an input that has
      # none - fail-open, so the 422 landed after the tag existed.
      if [[ "${GH_STUB_WF_DEFAULT_IN_DESCRIPTION:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        description: |\n          the version to build.\n          default: taken from the tag\n        required: true\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # The same description on an input that DOES declare a default: skipping
      # the block scalar must not start rejecting a dispatchable line.
      if [[ "${GH_STUB_WF_DESCRIPTION_AND_DEFAULT:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        description: |\n          the version to build.\n          default: taken from the tag\n        required: true\n        default: v0.0.0\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # TRUE is the same boolean as true. Matching only the lowercase spelling
      # read this input as optional and let the 422 land after the tag.
      if [[ "${GH_STUB_WF_REQUIRED_UPPERCASE:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        required: TRUE\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # A fully converted line saved with CRLF endings. The trailing CR defeated
      # the end-anchored key match while the trigger regex still matched, so it
      # was refused for an input it declares.
      if [[ "${GH_STUB_WF_CRLF:-}" == "1" ]]; then
        printf 'name: Release\r\non:\r\n  workflow_dispatch:\r\n    inputs:\r\n      triggered_by:\r\n        type: string\r\njobs: {}\r\n'; exit 0
      fi
      # Quoted spellings of the trigger token. Legal YAML, and the `on:` KEY
      # already tolerated quotes, so refusing these sent the operator to add a
      # trigger the file plainly has.
      if [[ "${GH_STUB_WF_QUOTED_SEQUENCE:-}" == "1" ]]; then
        printf 'on:\n  - "workflow_dispatch"\njobs: {}\n'; exit 0
      fi
      if [[ "${GH_STUB_WF_QUOTED_SCALAR:-}" == "1" ]]; then
        printf "on: 'workflow_dispatch'\njobs: {}\n"; exit 0
      fi
      if [[ "${GH_STUB_WF_QUOTED_KEY:-}" == "1" ]]; then
        printf 'on:\n  "workflow_dispatch":\njobs: {}\n'; exit 0
      fi
      # A quoted INPUT name. Captured with its quotes attached, it never matched
      # the name the dispatch passes, so a declared input read as missing.
      if [[ "${GH_STUB_WF_QUOTED_INPUT:-}" == "1" ]]; then
        printf "on:\n  workflow_dispatch:\n    inputs:\n      'triggered_by':\n        type: string\njobs: {}\n"; exit 0
      fi
      # gh writing a notice WHILE the body streams - the one ordering in which a
      # merged stderr line lands inside the `on:` block rather than before or
      # after it. Merged, that column-0 line ends the block early and the trigger
      # below it disappears.
      if [[ "${GH_STUB_WF_STDERR_MIDSTREAM:-}" == "1" ]]; then
        printf 'on:\n'
        echo "Warning: gh is out of date" >&2
        printf '  workflow_dispatch:\n    inputs:\n      triggered_by:\n        type: string\njobs: {}\n'
        exit 0
      fi
      # A multi-line default. Skipping the block scalar must not swallow the
      # `default:` KEY itself - that refused a line for an input that has one.
      if [[ "${GH_STUB_WF_MULTILINE_DEFAULT:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        required: true\n        default: |\n          v0.0.0\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # The folded spelling of the same thing.
      if [[ "${GH_STUB_WF_FOLDED_DEFAULT:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        required: true\n        default: >-\n          v0.0.0\n      triggered_by:\n        type: string\n'; exit 0
      fi
      # A flow sequence spread over lines: legal, dispatchable, and unreadable
      # here. Refused - but it must say so, not claim there is no trigger.
      if [[ "${GH_STUB_WF_MULTILINE_FLOW_SEQ:-}" == "1" ]]; then
        printf 'on: [\n  workflow_call,\n  workflow_dispatch\n]\njobs: {}\n'; exit 0
      fi
      # The one-line inline list, which dispatch_re does read. Pinned so the
      # flow-sequence refusal above cannot start swallowing it.
      if [[ "${GH_STUB_WF_INLINE_LIST:-}" == "1" ]]; then
        printf 'on: [workflow_call, workflow_dispatch]\njobs: {}\n'; exit 0
      fi
      # Half-converted: workflow_dispatch added, the old tag trigger left behind.
      # create_tag would start a second build racing the dispatched one.
      if [[ "${GH_STUB_WF_PUSH_TAGS:-}" == "1" ]]; then
        printf 'on:\n  push:\n    tags: ["v*"]\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\njobs: {}\n'; exit 0
      fi
      # A push trigger with no filter at all fires for every ref, tags included.
      if [[ "${GH_STUB_WF_PUSH_BARE:-}" == "1" ]]; then
        printf 'on:\n  push:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\njobs: {}\n'; exit 0
      fi
      # Filtered to branches, so it never sees a tag, and still refused: only a
      # dispatch may build.
      if [[ "${GH_STUB_WF_PUSH_BRANCHES:-}" == "1" ]]; then
        printf 'on:\n  push:\n    branches: [main]\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\njobs: {}\n'; exit 0
      fi
      # No push TRIGGER at all - just a workflow_dispatch input that happens to
      # be called push. An on:-wide grep refused the cut over it.
      if [[ "${GH_STUB_WF_INPUT_NAMED_PUSH:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\n      push:\n        description: whether to push images\n        default: "true"\njobs: {}\n'; exit 0
      fi
      # Both: an input named push that would read as a harmless filtered trigger,
      # ahead of the real tag-filtered one. The depth pin is what stops the input
      # from shadowing the trigger.
      if [[ "${GH_STUB_WF_INPUT_PUSH_SHADOWS:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\n      push:\n        branches: no\n  push:\n    tags: ["v*"]\njobs: {}\n'; exit 0
      fi
      # The list spellings of a real push trigger. They carry no filters, so each
      # fires for every ref - and each must still be caught now that the list
      # reading is depth-pinned rather than on:-wide.
      if [[ "${GH_STUB_WF_SEQ_PUSH:-}" == "1" ]]; then
        printf 'on:\n  - push\n  - workflow_dispatch\njobs: {}\n'; exit 0
      fi
      # The same sequence at the parent's indent.
      if [[ "${GH_STUB_WF_SEQ_PUSH_FLUSH:-}" == "1" ]]; then
        printf 'name: Release\non:\n- push\n- workflow_dispatch\njobs: {}\n'; exit 0
      fi
      if [[ "${GH_STUB_WF_INLINE_PUSH:-}" == "1" ]]; then
        printf 'on: [push, workflow_dispatch]\njobs: {}\n'; exit 0
      fi
      # A choice input whose options happen to include `push`. A sequence item,
      # like a list-form trigger, but nested four levels below one - and read at
      # any depth it hard-failed the cut over a trigger the file does not have.
      if [[ "${GH_STUB_WF_OPTION_NAMED_PUSH:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\n      mode:\n        type: choice\n        options:\n          - push\n          - dry-run\njobs: {}\n'; exit 0
      fi
      # Half-converted the other way: workflow_dispatch added, `release: created`
      # left behind. The dispatched build creating the release fires it.
      if [[ "${GH_STUB_WF_RELEASE_AND_DISPATCH:-}" == "1" ]]; then
        printf 'on:\n  release:\n    types: [created]\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\njobs: {}\n'; exit 0
      fi
      # `create` fires on the tag itself and takes no filter that would stop it.
      if [[ "${GH_STUB_WF_CREATE_AND_DISPATCH:-}" == "1" ]]; then
        printf 'on:\n  create:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\njobs: {}\n'; exit 0
      fi
      # The release-shaped mirror of the input named push.
      if [[ "${GH_STUB_WF_INPUT_NAMED_RELEASE:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\n      release:\n        description: whether to publish\n        default: "true"\njobs: {}\n'; exit 0
      fi
      # A multi-line flow sequence with an unfiltered push on its second line.
      if [[ "${GH_STUB_WF_FLOW_SEQ_DISPATCH_FIRST:-}" == "1" ]]; then
        printf 'on: [workflow_dispatch,\n  push]\njobs: {}\n'; exit 0
      fi
      # A single input written inline, required and with no default.
      if [[ "${GH_STUB_WF_INPUT_INLINE:-}" == "1" ]]; then
        printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        required: false\n      version: {required: true, description: x}\njobs: {}\n'; exit 0
      fi
      printf 'on:\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        type: string\n'
      exit 0 ;;
    repos/*/actions/workflows/*)
      # Read by require_workflow_active. GH_STUB_WF_STATE sets the state GitHub
      # reports, and `missing` makes the workflow unknown to it.
      fail_if_simulated workflows
      [[ -n "${GH_STUB_CONTENTS_LOG:-}" ]] && printf '%s\n' "$path" >>"$GH_STUB_CONTENTS_LOG"
      [[ "${GH_STUB_WF_STATE:-active}" == "missing" ]] && respond 404
      respond 200 "$(printf '{"path":".github/workflows/release.yaml","state":"%s"}' "${GH_STUB_WF_STATE:-active}")" ;;
    *)
      # The repo read require_push_access makes. A token that cannot see a
      # private repo gets a 404 here, which GH_STUB_REPO_HIDDEN reproduces.
      # GH_STUB_PUSH_PERM=false|absent reproduces a read-only token and a
      # GitHub App token, which gets no permissions object at all.
      if [[ "$path" =~ ^repos/[^/]+/[^/]+$ ]]; then
        fail_if_simulated repo
        [[ "${GH_STUB_REPO_HIDDEN:-}" == "1" ]] && respond 404
        case "${GH_STUB_PUSH_PERM:-true}" in
          absent) body='{"full_name":"x"}' ;;
          *) body="$(printf '{"permissions":{"pull":true,"push":%s}}' "${GH_STUB_PUSH_PERM:-true}")" ;;
        esac
        respond 200 "$body"
      fi
      # Anything else: succeed.
      exit 0 ;;
  esac
fi

if [[ "$sub" == "workflow" && "${1:-}" == "run" ]]; then
  # GH_STUB_DISPATCH_FAILS=1 simulates the real 422 a line whose release.yaml has
  # no workflow_dispatch trigger (or does not declare an input being passed)
  # returns - the case that leaves an orphan tag behind.
  if [[ "${GH_STUB_DISPATCH_FAILS:-}" == "1" ]]; then
    echo "HTTP 422: Unexpected inputs provided" >&2
    exit 1
  fi
  printf 'stub-dispatch %s\n' "$*"
  # The run GitHub queues, of the tag just created or the one resumed.
  # GH_STUB_DISPATCH_INVISIBLE=1 keeps it out of the run list, as when GitHub
  # is slow to list it.
  if [[ "${GH_STUB_DISPATCH_INVISIBLE:-}" != "1" ]]; then
    queued_sha="$(cat "${state_dir}/posted_sha" 2>/dev/null || printf '%s' "${GH_STUB_TAG_SHA:-$STUB_TAG_COMMIT}")"
    if [[ -n "${GH_STUB_DISPATCH_VISIBLE_AFTER:-}" ]]; then
      printf '%s:queued:null ' "$queued_sha" >"${state_dir}/dispatch_pending"
    else
      printf '%s:queued:null ' "$queued_sha" >>"${state_dir}/dispatched_runs"
    fi
  fi
  exit 0
fi

exit 0
EOF
  chmod +x "${STUB_DIR}/gh"
}

# ---- normalize_version (pure) ----

@test "normalize_version: bare version gains the leading v" {
  run normalize_version "4.11.3"
  [ "$status" -eq 0 ]
  [ "$output" = "v4.11.3" ]
}

@test "normalize_version: already-canonical version is untouched" {
  run normalize_version "v4.11.3"
  [ "$output" = "v4.11.3" ]
}

@test "trim: leading and trailing whitespace is stripped" {
  run trim "  release-4.11  "
  [ "$output" = "release-4.11" ]
}

@test "trim: an all-whitespace value collapses to empty" {
  run trim "   "
  [ "$output" = "" ]
}

@test "normalize_version: capitalized V is lowercased" {
  run normalize_version "V4.11.3"
  [ "$output" = "v4.11.3" ]
}

@test "normalize_version: surrounding whitespace is stripped" {
  run normalize_version "  v4.11.3  "
  [ "$output" = "v4.11.3" ]
}

@test "normalize_version: whitespace and a missing v are both repaired" {
  run normalize_version " 4.12.0-rc.1 "
  [ "$output" = "v4.12.0-rc.1" ]
}

# ---- validate_version (pure) ----

@test "validate_version: accepts a stable version" {
  run validate_version "v4.11.3"
  [ "$status" -eq 0 ]
}

@test "validate_version: accepts an rc suffix" {
  run validate_version "v4.12.0-rc.1"
  [ "$status" -eq 0 ]
}

@test "validate_version: accepts a next.internal suffix" {
  run validate_version "v4.13.0-next.internal.3"
  [ "$status" -eq 0 ]
}

@test "validate_version: rejects a major.minor line name" {
  run validate_version "v4.11"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
}

@test "validate_version: rejects a four-component version" {
  run validate_version "v4.11.3.1"
  [ "$status" -ne 0 ]
}

@test "validate_version: rejects a bare version (normalize runs first)" {
  run validate_version "4.11.3"
  [ "$status" -ne 0 ]
}

@test "validate_version: rejects build metadata" {
  run validate_version "v4.11.3+build.5"
  [ "$status" -ne 0 ]
}

@test "validate_version: rejects a leading zero in any numeric component" {
  # The typo nothing downstream catches: v4.11.02 normalizes unchanged, derives
  # release-4.11 (which exists), and probes clean against the double-cut guard
  # because the shipped tag is v4.11.2 - so the cut would tag a version the Go
  # module proxy can never resolve.
  run validate_version "v4.11.02"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
  run validate_version "v04.11.2"
  [ "$status" -ne 0 ]
  run validate_version "v4.011.2"
  [ "$status" -ne 0 ]
  run validate_version "v4.11.2-rc.01"
  [ "$status" -ne 0 ]
}

@test "validate_version: rejects an empty prerelease identifier" {
  # `v4.12.0-rc.` survives a paste out of a sentence. classify_suffix catches it
  # too; this is the earlier of the two gates.
  run validate_version "v4.12.0-rc."
  [ "$status" -ne 0 ]
  run validate_version "v4.12.0-rc..1"
  [ "$status" -ne 0 ]
  run validate_version "v4.12.0-"
  [ "$status" -ne 0 ]
}

@test "validate_version: the shapes the pipeline actually cuts still pass" {
  # The semver identifier grammar is stricter than the old character class, so
  # the hyphenated and multi-part suffixes in live use are pinned here: a regex
  # that rejected one of these would block a cut outright.
  local v
  for v in v4.11.2 v0.0.0 v4.12.0-rc.1 v4.12.0-next.1 v4.13.0-next.internal.3 \
           v4.11.2-hotfix-rc.1 v4.12.0-devpod-alpha.1 v4.12.0-alpha.foo; do
    run validate_version "$v"
    [ "$status" -eq 0 ]
  done
}

@test "validate_version: rejects a release branch name" {
  run validate_version "release-4.11"
  [ "$status" -ne 0 ]
}

# ---- main validation gates ----

@test "main: a missing version input fails loudly" {
  # Annotated, not a bare `${VAR:?}` abort: GitHub does not enforce
  # `required: true` on a composite input, so this is reachable from a caller
  # and the run needs something in its annotations panel.
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::version is required"* ]]
}

@test "main: an empty version input is refused the same way" {
  INPUT_VERSION="" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::version is required"* ]]
}

@test "main: an invalid version never reaches the API" {
  INPUT_VERSION="v4.11" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
  [[ "$output" != *"[dry-run]"* ]]
}

@test "main: a leading-zero typo never reaches the API" {
  # The one shape where every later gate reads clean: the line release-4.11
  # exists, and the double-cut probe 404s because the shipped tag is v4.11.2.
  # Only the version gate stands between the typo and a tagged, dispatched
  # build of a version the Go module proxy cannot resolve.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.02" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "main: a capitalized V is normalized and reported" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="V4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"normalized version 'V4.11.3' -> 'v4.11.3'"* ]]
  [[ "$output" == *"ref=refs/tags/v4.11.3"* ]]
}

@test "main: a canonical version logs no normalization notice" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"normalized version"* ]]
}

@test "main: a bare version tags the v-prefixed name" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=refs/tags/v4.11.3"* ]]
  [[ "$output" != *"refs/tags/4.11.3 "* ]]
}

@test "main: a bare version does NOT bypass the double-cut guard" {
  # The regression normalization exists to prevent: probing for "4.11.3" 404s
  # while "v4.11.3" is already shipped, silently re-releasing it.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release v4.11.3 already exists"* ]]
}

@test "main: a truncated bare version still fails after normalization" {
  INPUT_VERSION="4.11" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
}

# ---- parse_major_minor (pure) ----

@test "parse_major_minor: v-prefixed patch+prerelease -> major minor" {
  run parse_major_minor "v4.11.3-rc.1"
  [ "$status" -eq 0 ]
  [ "$output" = "4 11" ]
}

@test "parse_major_minor: bare major.minor" {
  run parse_major_minor "5.0"
  [ "$output" = "5 0" ]
}

@test "parse_major_minor: double-digit minor" {
  run parse_major_minor "v4.13.0"
  [ "$output" = "4 13" ]
}

@test "parse_major_minor: fails on garbage" {
  run parse_major_minor "not-a-version"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot parse major.minor"* ]]
}

# ---- derive_line (pure) ----

@test "derive_line: produces the release-X.Y branch name" {
  run derive_line "v4.11.3"
  [ "$status" -eq 0 ]
  [ "$output" = "release-4.11" ]
}

@test "derive_line: double-digit minor is not truncated" {
  run derive_line "v4.13.0-next.internal.1"
  [ "$output" = "release-4.13" ]
}

@test "derive_line: honours a LINE_BRANCH_FORMAT override" {
  LINE_BRANCH_FORMAT="v%s.%s" run derive_line "v4.11.3"
  [ "$output" = "v4.11" ]
}

# ---- classify_suffix (pure) ----

@test "classify_suffix: stable" {
  run classify_suffix "v4.11.3"
  [ "$output" = "stable" ]
}

@test "classify_suffix: rc" {
  run classify_suffix "v4.12.0-rc.1"
  [ "$output" = "rc" ]
}

@test "classify_suffix: alpha" {
  run classify_suffix "v4.12.0-alpha.5"
  [ "$output" = "alpha" ]
}

@test "classify_suffix: beta" {
  run classify_suffix "v4.12.0-beta.1"
  [ "$output" = "beta" ]
}

@test "classify_suffix: next" {
  run classify_suffix "v4.12.0-next.1"
  [ "$output" = "next" ]
}

@test "classify_suffix: next.internal wins over next" {
  run classify_suffix "v4.13.0-next.internal.2"
  [ "$output" = "next-internal" ]
}

@test "classify_suffix: rejects an unrouted suffix" {
  # loft-enterprise carries historical -devpod.alpha and -kubernetes tags; a
  # legal-but-unrouted suffix must be rejected, never guessed onto a branch.
  run classify_suffix "v4.12.0-devpod.alpha.1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported prerelease suffix"* ]]
}

@test "classify_suffix: rejects a dash-spelled unrouted suffix" {
  # The dashed spelling of the same unrouted flavor. An unanchored glob matches
  # -alpha. anywhere in the string, so this one classified as a plain alpha and
  # would have been cut from main.
  run classify_suffix "v4.12.0-devpod-alpha.1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported prerelease suffix"* ]]
}

@test "classify_suffix: rejects a dash-prefixed rc flavor" {
  run classify_suffix "v4.11.2-hotfix-rc.1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported prerelease suffix"* ]]
}

@test "classify_suffix: rejects a suffix without a numeric component" {
  run classify_suffix "v4.12.0-rc"
  [ "$status" -ne 0 ]
  # The message has to name the numeric component the patterns require, or it
  # sends the operator looking for a classifier bug instead of fixing the tag.
  [[ "$output" == *"-rc.N"* ]]
}

@test "classify_suffix: rejects a trailing-dot suffix" {
  # validate_version rejects this too, now that the prerelease body is read as
  # semver identifiers. Kept as its own gate: the classifier is what the routing
  # depends on, and it must not start accepting an empty counter if that regex
  # is ever loosened.
  run classify_suffix "v4.12.0-rc."
  [ "$status" -ne 0 ]
}

@test "classify_suffix: rejects a non-numeric counter" {
  run classify_suffix "v4.12.0-alpha.foo"
  [ "$status" -ne 0 ]
}

@test "classify_suffix: rejects next.internal without a counter" {
  # Must not fall through to the looser next arm: routing is the same either way,
  # but the log and every error message would name the wrong flavour.
  run classify_suffix "v4.13.0-next.internal"
  [ "$status" -ne 0 ]
}

# ---- config constants ----
#
# Run as a subprocess, not sourced: the hazard is environment inheritance (a
# composite action's steps inherit the caller's workflow- and job-level `env:`),
# and `VAR=x source` does not reproduce that - it leaves the sourced script
# reading the shell variable and passes whether or not the fix is in place.

@test "config: an ambient REPO cannot redirect the cut" {
  # If REPO bled through, every probe, the tag and the dispatch would follow it
  # to the wrong repository while the dry-run output still read as consistent.
  run env REPO="attacker/repo" \
    GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11" \
    INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"loft-sh/loft-enterprise"* ]]
  [[ "$output" != *"attacker/repo"* ]]
}

@test "config: an ambient DEFAULT_BRANCH cannot redirect the cut" {
  run env DEFAULT_BRANCH="attacker-branch" \
    GH_STUB_BRANCHES="loft-sh/loft-enterprise:main" \
    INPUT_VERSION="v4.12.0-alpha.1" INPUT_DRY_RUN="true" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"target main"* ]]
  [[ "$output" != *"attacker-branch"* ]]
}

@test "config: the PLATFORM_-prefixed override is still honoured" {
  # The deliberate seam, kept so a direct invocation can retarget the dispatcher.
  run env PLATFORM_REPO="loft-sh/other" \
    GH_STUB_BRANCHES="loft-sh/other:release-4.11" \
    INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"loft-sh/other"* ]]
}

# ---- is_feature_branch (pure) ----

@test "is_feature_branch: main is not a feature branch" {
  run is_feature_branch "main"
  [ "$status" -ne 0 ]
}

@test "is_feature_branch: a release line branch is not a feature branch" {
  run is_feature_branch "release-4.11"
  [ "$status" -ne 0 ]
}

@test "is_feature_branch: a double-digit release line branch is not a feature branch" {
  run is_feature_branch "release-4.13"
  [ "$status" -ne 0 ]
}

@test "is_feature_branch: a topic branch is a feature branch" {
  run is_feature_branch "engplat-406/private-nodes"
  [ "$status" -eq 0 ]
}

@test "is_feature_branch: a release-prefixed topic branch is a feature branch" {
  # release-4.11-hotfix is NOT the 4.11 line branch; the pattern is anchored.
  run is_feature_branch "release-4.11-hotfix"
  [ "$status" -eq 0 ]
}

# ---- resolve_target (pure) ----

@test "resolve_target: alpha defaults to main" {
  run resolve_target alpha "" release-4.12
  [ "$output" = "main" ]
}

@test "resolve_target: alpha from main is allowed" {
  run resolve_target alpha main release-4.12
  [ "$output" = "main" ]
}

@test "resolve_target: alpha from a release branch is rejected" {
  run resolve_target alpha release-4.12 release-4.12
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from main only"* ]]
}

@test "resolve_target: beta from a release branch is rejected" {
  run resolve_target beta release-4.12 release-4.12
  [ "$status" -ne 0 ]
}

@test "resolve_target: rc with an empty source-branch is refused" {
  # resolve_rc_source fills the branch in on every live path. Defaulting to main
  # here would skip its refusal of main once the line has branched.
  run resolve_target rc "" release-4.12
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolve_rc_source"* ]]
}

@test "resolve_target: rc from main is allowed" {
  # Legal by the matrix; whether it is legal for THIS line is resolve_rc_source's
  # call, which runs first.
  run resolve_target rc main release-4.11
  [ "$output" = "main" ]
}

@test "resolve_target: rc from the line branch is allowed" {
  run resolve_target rc release-4.11 release-4.11
  [ "$output" = "release-4.11" ]
}

@test "resolve_target: rc from a different line branch is rejected" {
  run resolve_target rc release-4.10 release-4.11
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from main or the release-4.11 release branch"* ]]
}

@test "resolve_target: stable resolves to the line branch" {
  run resolve_target stable "" release-4.11
  [ "$output" = "release-4.11" ]
}

@test "resolve_target: stable from main is rejected" {
  run resolve_target stable main release-4.11
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from the release-4.11 release branch only"* ]]
}

@test "resolve_target: an unexpected suffix is rejected" {
  run resolve_target next "" release-4.13
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected suffix"* ]]
}

# ---- main: dry-run routing ----

@test "main: stable is tagged on the line branch and dispatched at the tag" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"line=release-4.11"* ]]
  [[ "$output" == *"ref=refs/tags/v4.11.3 -f sha=head-release-4.11"* ]]
  [[ "$output" == *"gh workflow run release.yaml --repo loft-sh/loft-enterprise --ref refs/tags/v4.11.3"* ]]
}

@test "main: alpha is tagged on main" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  INPUT_VERSION="v4.12.0-alpha.6" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=refs/tags/v4.12.0-alpha.6 -f sha=head-main"* ]]
}

@test "main: alpha is refused once the line has branched" {
  # main carries the next line by then, so the tag would land on the wrong code.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main loft-sh/loft-enterprise:release-4.12"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.12.0-alpha.6" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release-4.12 exists"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: beta is refused once the line has branched, even from an explicit main" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main loft-sh/loft-enterprise:release-4.12"
  INPUT_VERSION="v4.12.0-beta.2" INPUT_SOURCE_BRANCH="main" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release-4.12 exists"* ]]
  [[ "$output" != *"[dry-run] gh api -X POST"* ]]
}

@test "main: a transient failure on the alpha line probe aborts instead of taking main" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  export GH_STUB_TRANSIENT=1
  INPUT_VERSION="v4.12.0-alpha.6" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to reach GitHub API"* ]]
  [[ "$output" != *"[dry-run] gh api -X POST"* ]]
}

@test "main: a repo the token cannot see is named as a token problem, not a missing branch" {
  # GitHub answers 404 for a private repo the token has no access to, so without
  # this the rc probe reads "no line branch" and the cut blames a missing main.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  export GH_STUB_REPO_HIDDEN=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.12.0-rc.1" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot see loft-sh/loft-enterprise"* ]]
  [[ "$output" != *"does not exist yet"* ]]
  [[ "$output" != *"not found"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "main: a transient failure on the repo probe aborts rather than reading as hidden" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  export GH_STUB_TRANSIENT_REPO=1
  INPUT_VERSION="v4.12.0-rc.1" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to reach GitHub API for repository loft-sh/loft-enterprise"* ]]
  [[ "$output" != *"cannot see"* ]]
}

@test "main: rc with no source-branch falls back to main when the line branch is absent" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  INPUT_VERSION="v4.12.0-rc.1" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"release-4.12 does not exist yet"* ]]
  [[ "$output" == *"sha=head-main"* ]]
}

@test "main: rc with no source-branch is auto-routed to the line branch when it exists" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3-rc.1" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"release-4.11 exists in loft-sh/loft-enterprise"* ]]
  [[ "$output" == *"sha=head-release-4.11"* ]]
  [[ "$output" != *"sha=head-main"* ]]
}

@test "main: rc explicitly from main is refused once the line branch exists" {
  # The divergence this closes: main carries the next line's development, so a
  # 4.11.3 candidate cut from it validates the wrong code and nothing downstream
  # would catch it. Matches the vcluster-release sibling exactly.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3-rc.1" INPUT_SOURCE_BRANCH="main" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from release-4.11, not from main"* ]]
  # Refused before anything is printed as about to be cut.
  [[ "$output" != *"[dry-run] gh api"* ]]
}

@test "main: rc explicitly from main is still allowed before the line branches" {
  # A first minor rc has no release-4.12 branch yet, so main IS the line.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  INPUT_VERSION="v4.12.0-rc.1" INPUT_SOURCE_BRANCH="main" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"sha=head-main"* ]]
}

@test "main: a transient failure on the rc line probe aborts instead of taking main" {
  # Reading an unreachable API as "no line branch yet" would send a patch rc to
  # main - the mistake the auto-route exists to prevent.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TRANSIENT=1
  INPUT_VERSION="v4.11.3-rc.1" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Not treating as absent"* ]]
  [[ "$output" != *"[dry-run] gh api"* ]]
}

@test "main: rc with the line branch is tagged there" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3-rc.1" INPUT_SOURCE_BRANCH="release-4.11" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"sha=head-release-4.11"* ]]
}

@test "main: stable from main is rejected before any mutation" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_SOURCE_BRANCH="main" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from the release-4.11 release branch only"* ]]
  [[ "$output" != *"[dry-run] gh api"* ]]
}

@test "main: next.internal is cut from the named feature branch" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:engplat-406/private-nodes"
  INPUT_VERSION="v4.13.0-next.internal.3" INPUT_SOURCE_BRANCH="engplat-406/private-nodes" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"sha=head-engplat-406/private-nodes"* ]]
  [[ "$output" == *"--ref refs/tags/v4.13.0-next.internal.3"* ]]
}

@test "main: next without a source-branch is rejected" {
  INPUT_VERSION="v4.13.0-next.1" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"require the source-branch input"* ]]
}

@test "main: next from main is rejected" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  INPUT_VERSION="v4.13.0-next.1" INPUT_SOURCE_BRANCH="main" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from a short-lived feature branch"* ]]
}

@test "main: next from a release line branch is rejected" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.13.0-next.internal.1" INPUT_SOURCE_BRANCH="release-4.11" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"cut from a short-lived feature branch"* ]]
}

@test "main: an unrouted suffix is rejected before any mutation" {
  INPUT_VERSION="v4.12.0-devpod.alpha.1" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported prerelease suffix"* ]]
  [[ "$output" != *"[dry-run]"* ]]
}

@test "main: dry-run mutates nothing" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] gh api -X POST"* ]]
  [[ "$output" == *"[dry-run] gh workflow run"* ]]
  [[ "$output" != *"created tag"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: an unrecognized dry-run value falls back to dry-run" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="yes" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecognized dry-run value 'yes'"* ]]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" != *"created tag"* ]]
}

@test "main: an empty dry-run value stays in dry-run" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "main: an upper-case FALSE still cuts for real" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="FALSE" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"created tag v4.11.3"* ]]
}

# ---- main: guards ----

@test "main: a missing target branch is a hard error" {
  export GH_STUB_BRANCHES=""
  INPUT_VERSION="v4.14.0" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"branch 'release-4.14' not found"* ]]
  [[ "$output" == *"refusing to guess"* ]]
}

@test "main: an existing release is a hard error (double-cut guard)" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to re-cut"* ]]
}

@test "main: an existing tag with no build resumes at the dispatch" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming at the dispatch without re-tagging"* ]]
  [[ "$output" != *"[dry-run] gh api -X POST"* ]]
  [[ "$output" == *"[dry-run] gh workflow run release.yaml --repo loft-sh/loft-enterprise --ref refs/tags/v4.11.3"* ]]
}

@test "main: an existing rc tag does not block the stable cut" {
  # Regression guard for the plural git/refs/tags/ endpoint, which prefix-matches
  # and would report v4.11.3 as tagged when only v4.11.3-rc.1 exists.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3-rc.1"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=refs/tags/v4.11.3"* ]]
}

@test "main: a transient API failure is not read as an absent release" {
  # The release listing is the first read a stable cut makes after the repo
  # probe.
  export GH_STUB_TRANSIENT=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list releases"* ]]
  [[ "$output" == *"Not treating as absent"* ]]
  [[ "$output" == *"dial tcp"* ]]
}

@test "main: a transient API failure on the tag probes aborts the cut" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TRANSIENT_TAGS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to reach GitHub API"* ]]
  [[ "$output" != *"[dry-run] gh api -X POST"* ]]
}

@test "main: a transient API failure on the target branch read is not read as a missing branch" {
  # A stable cut makes no branch_exists probe, so resolve_head is its only
  # missing-branch guard, and it runs inside a command substitution.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TRANSIENT_HEADS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to reach GitHub API for branch 'release-4.11'"* ]]
  [[ "$output" == *"Not treating as absent"* ]]
  [[ "$output" != *"not found"* ]]
  [[ "$output" != *"[dry-run] gh api -X POST"* ]]
}

@test "main: an unexpected API status aborts instead of falling back" {
  export GH_STUB_UNEXPECTED=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected status 403"* ]]
}

# ---- main: the live (non-dry-run) path ----

@test "main: a real cut POSTs the tag ref at the branch head sha" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  # head-<branch> is what the stubbed git/ref/heads read returns for a known
  # branch, so this pins the sha through create_tag rather than trusting its echo.
  run grep -F 'repos/loft-sh/loft-enterprise/git/refs' "$GH_STUB_CALL_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=refs/tags/v4.11.3"* ]]
  [[ "$output" == *"sha=head-release-4.11"* ]]
}

@test "main: a rejected tag POST fails loudly and dispatches nothing" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAG_POST_FAILS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to create tag v4.11.3"* ]]
  # Nothing may be dispatched against a tag that was never created. Matched on
  # dispatch()'s own success line, because the error above says "Nothing was
  # dispatched" and a bare "dispatched" would match that instead.
  [[ "$output" != *"dispatched release.yaml"* ]]
}

@test "api_exists: a transient failure surfaces gh's own error" {
  export GH_STUB_TRANSIENT=1
  run api_exists "repos/loft-sh/loft-enterprise/branches/main" "branch main"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Not treating as absent"* ]]
  # The whole point of the fix: the three-cause guess is useless without gh's
  # own line naming which of them it actually was.
  [[ "$output" == *"dial tcp"* ]]
}

@test "api_exists: a multi-line gh error cannot forge a workflow command" {
  export GH_STUB_TRANSIENT=1 GH_STUB_TRANSIENT_MULTILINE=1
  run api_exists "repos/loft-sh/loft-enterprise/branches/main" "branch main"
  [ "$status" -ne 0 ]
  # Kept as inline text so the diagnostic is not lost...
  [[ "$output" == *"FORGED"* ]]
  # ...but flattened, so it cannot start a line and be read as a second command.
  [ "$(printf '%s\n' "$output" | grep -c '^::error::')" -eq 1 ]
}

@test "main: a real cut tags the branch then dispatches the tag" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"created tag v4.11.3 in loft-sh/loft-enterprise at release-4.11 (head-release-4.11)"* ]]
  [[ "$output" == *"dispatched release.yaml in loft-sh/loft-enterprise at v4.11.3"* ]]
  # The tag must exist before the builder is dispatched, or the dispatch 404s.
  tag_line=$(printf '%s\n' "$output" | grep -n 'created tag' | head -1 | cut -d: -f1)
  run_line=$(printf '%s\n' "$output" | grep -n 'dispatched release.yaml' | head -1 | cut -d: -f1)
  [ -n "$tag_line" ] && [ -n "$run_line" ] && [ "$tag_line" -lt "$run_line" ]
}

@test "main: a real cut forwards triggered_by when set" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  TRIGGERED_BY="dmytrosydorov" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ref refs/tags/v4.11.3 -f triggered_by=dmytrosydorov"* ]]
}

@test "main: a real cut omits triggered_by when unset" {
  # gh workflow run rejects undeclared inputs, so an empty actor must not become
  # `-f triggered_by=`.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  TRIGGERED_BY="" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"triggered_by"* ]]
}

@test "main: a real cut forwards the branch it tagged when release.yaml declares source_branch" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_SOURCE_BRANCH=1
  TRIGGERED_BY="dmytrosydorov" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"-f triggered_by=dmytrosydorov -f source_branch=release-4.11"* ]]
}

@test "main: an alpha cut names main as its source branch" {
  # Once main moves past the tag, git history alone cannot tell main from a
  # branch forked at the tag.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  export GH_STUB_WF_SOURCE_BRANCH=1
  TRIGGERED_BY="" INPUT_VERSION="v4.13.0-alpha.20" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ref refs/tags/v4.13.0-alpha.20 -f source_branch=main"* ]]
}

@test "main: a -next cut names its feature branch as the source branch" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:feature/foo"
  export GH_STUB_WF_SOURCE_BRANCH=1
  TRIGGERED_BY="" INPUT_VERSION="v4.12.0-next.1" INPUT_SOURCE_BRANCH="feature/foo" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"-f source_branch=feature/foo"* ]]
}

@test "main: a declared string source_branch is forwarded" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_SOURCE_BRANCH_TYPE=string
  TRIGGERED_BY="dmytrosydorov" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"-f source_branch=release-4.11"* ]]
}

@test "main: a resumed rc on its line leaves source_branch to the notifier" {
  # The tag may predate the line, and only the notifier's history can tell.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.0-rc.2"
  export GH_STUB_WF_SOURCE_BRANCH_TYPE=string
  TRIGGERED_BY="" INPUT_VERSION="v4.11.0-rc.2" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming at the dispatch"* ]]
  [[ "$output" == *"not passing source_branch"* ]]
  [[ "$output" != *"-f source_branch"* ]]
}

@test "main: a resumed rc still passes source_branch when release.yaml requires it" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.0-rc.2"
  export GH_STUB_WF_SOURCE_BRANCH=1
  TRIGGERED_BY="" INPUT_VERSION="v4.11.0-rc.2" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"-f source_branch=release-4.11"* ]]
}

@test "main: a resumed rc on its line is not refused over a choice source_branch it does not pass" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.0-rc.2"
  export GH_STUB_WF_SOURCE_BRANCH_TYPE=choice
  TRIGGERED_BY="" INPUT_VERSION="v4.11.0-rc.2" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"not passing source_branch"* ]]
  [[ "$output" != *"-f source_branch"* ]]
}

@test "main: a resumed rc on its line is not refused over a boolean source_branch it does not pass" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.0-rc.2"
  export GH_STUB_WF_SOURCE_BRANCH_TYPE=boolean
  TRIGGERED_BY="" INPUT_VERSION="v4.11.0-rc.2" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"not passing source_branch"* ]]
  [[ "$output" != *"-f source_branch"* ]]
}

@test "main: a resumed rc still type-checks a source_branch it has to pass" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.0-rc.2"
  export GH_STUB_WF_SOURCE_BRANCH=1
  export GH_STUB_WF_SOURCE_BRANCH_TYPE=choice
  TRIGGERED_BY="" INPUT_VERSION="v4.11.0-rc.2" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"declares 'source_branch' under workflow_dispatch with type 'choice'"* ]]
}

@test "main: a resumed rc leaves out a required source_branch that has a default" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.0-rc.2"
  export GH_STUB_WF_SOURCE_BRANCH=1
  export GH_STUB_WF_SOURCE_BRANCH_DEFAULT=main
  TRIGGERED_BY="" INPUT_VERSION="v4.11.0-rc.2" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"not passing source_branch"* ]]
  [[ "$output" != *"-f source_branch"* ]]
}

@test "main: a resumed stable still type-checks source_branch" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_WF_SOURCE_BRANCH_TYPE=choice
  TRIGGERED_BY="" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"declares 'source_branch' under workflow_dispatch with type 'choice'"* ]]
}

@test "main: a resumed stable passes the line as source_branch" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_WF_SOURCE_BRANCH_TYPE=string
  TRIGGERED_BY="" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming at the dispatch"* ]]
  [[ "$output" == *"-f source_branch=release-4.11"* ]]
}

@test "main: a source_branch input that is not a string is refused before tagging" {
  # A choice or boolean input can reject the branch name, failing the
  # dispatch after the tag exists.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  for t in choice boolean String false '~' '"Str ing"'; do
    export GH_STUB_WF_SOURCE_BRANCH_TYPE="$t"
    TRIGGERED_BY="dmytrosydorov" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares 'source_branch' under workflow_dispatch with "*"Nothing was tagged"* ]]
    [[ "$output" != *"ref=refs/tags/v4.11.3 -f sha="* ]]
  done
}

@test "main: the refusal names the declared type" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_SOURCE_BRANCH_TYPE=String
  TRIGGERED_BY="dmytrosydorov" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"with type 'String'"* ]]
}

@test "main: a triggered_by input that is not a string is refused before tagging" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_TRIGGERED_BY_TYPE=choice
  TRIGGERED_BY="dmytrosydorov" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"declares 'triggered_by' under workflow_dispatch with type 'choice'"* ]]
  [[ "$output" != *"ref=refs/tags/v4.11.3 -f sha="* ]]
}

@test "main: a real cut omits source_branch when release.yaml does not declare it" {
  # Lines cut before the input existed must keep dispatching: gh workflow run
  # rejects an undeclared input.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  TRIGGERED_BY="dmytrosydorov" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"source_branch"* ]]
}

@test "main: a guarded version never reaches the dispatch on a real cut" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" != *"created tag"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a pasted source-branch with surrounding whitespace still routes" {
  # The same paste that drops a space next to a version drops one next to a
  # branch; untrimmed, this failed the stable check quoting back a value that
  # looked identical to the expected one.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_SOURCE_BRANCH="  release-4.11  " INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"source-branch=release-4.11"* ]]
  [[ "$output" == *"ref=refs/tags/v4.11.3"* ]]
}

@test "main: a failed dispatch leaves the tag in place" {
  # gh exiting non-zero does not prove the dispatch was rejected, so deleting the
  # tag could pull it out from under a queued build.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DISPATCH_FAILS=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"created tag v4.11.3"* ]]
  [[ "$output" == *"failed to dispatch release.yaml"* ]]
  [[ "$output" == *"Tag v4.11.3 stays in place"* ]]
  [[ "$output" == *"re-run the cut with the same version"* ]]
  ! grep -q -- "-X DELETE" "${STUB_DIR}/calls"
}

@test "main: a ref response without .object.sha is refused before anything is tagged" {
  # Without `// empty` jq prints the literal "null" and exits 0, and that string
  # would reach both the preflight and the tag POST as the sha.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_HEAD_NO_SHA=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not resolve HEAD sha for branch 'release-4.11'"* ]]
  [[ "$output" != *"null"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
  [[ "$output" != *"stub-dispatch"* ]]
}

# ---- resolve_rc_source (branch-state aware) ----

@test "resolve_rc_source: an empty source-branch takes the line branch when it exists" {
  # The finding this encodes: a patch rc routed to main would tag unreleased
  # next-minor code as a 4.11.3 candidate.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  run resolve_rc_source loft-sh/loft-enterprise release-4.11 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"release-4.11"* ]]
}

@test "resolve_rc_source: an empty source-branch takes main before the line branches" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  run resolve_rc_source loft-sh/loft-enterprise release-4.12 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]]
}

@test "resolve_rc_source: an explicit main is refused once the line branch exists" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  run resolve_rc_source loft-sh/loft-enterprise release-4.11 main
  [ "$status" -ne 0 ]
  [[ "$output" == *"lacks the fixes backported to release-4.11"* ]]
}

@test "resolve_rc_source: an explicit main is honoured before the line branches" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  run resolve_rc_source loft-sh/loft-enterprise release-4.12 main
  [ "$status" -eq 0 ]
  [[ "$output" == "main" ]]
}

@test "resolve_rc_source: an unrelated source-branch passes through for resolve_target to reject" {
  # One rejection site for a bad branch name, not two.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  run resolve_rc_source loft-sh/loft-enterprise release-4.11 release-4.10
  [ "$status" -eq 0 ]
  [[ "$output" == "release-4.10" ]]
}

@test "resolve_rc_source: a transient failure on the line probe aborts instead of taking main" {
  export GH_STUB_TRANSIENT=1
  run resolve_rc_source loft-sh/loft-enterprise release-4.11 ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"Not treating as absent"* ]]
}

# ---- require_dispatchable (pre-tag preflight) ----

@test "require_dispatchable: a workflow_dispatch workflow passes" {
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a release-triggered workflow is refused" {
  export GH_STUB_WF_NO_DISPATCH=1
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"no workflow_dispatch trigger"* ]]
  [[ "$output" == *"Nothing was tagged"* ]]
}

@test "require_dispatchable: a missing triggered_by input is refused when one is passed" {
  export GH_STUB_WF_NO_TRIGGERED_BY=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares no 'triggered_by' input"* ]]
}

@test "require_dispatchable: a missing triggered_by input is fine when none is passed" {
  # A direct script invocation leaves TRIGGERED_BY empty, and the dispatch then
  # passes no input, so the declaration is not required.
  export GH_STUB_WF_NO_TRIGGERED_BY=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: an unreadable workflow file aborts with gh's reason" {
  export GH_STUB_WF_UNREADABLE=1
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot confirm the build is dispatchable"* ]]
  [[ "$output" == *"Not Found"* ]]
}

@test "main: an undispatchable line is refused before the tag is created" {
  # The orphan-tag class: the tag is created before the dispatch, so a line still
  # on release:created would strand one and then be blocked by the double-cut
  # guard on the retry.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_NO_DISPATCH=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"no workflow_dispatch trigger"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "main: a dry-run against an undispatchable line fails rather than printing a doomed cut" {
  # Dry-run skips the dispatch, so without a read-only preflight this is exactly
  # the case a preview cannot catch.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_NO_DISPATCH=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"no workflow_dispatch trigger"* ]]
  [[ "$output" != *"[dry-run] gh workflow run"* ]]
}

# ---- diagnostics ----

@test "api_exists: an unexpected status carries gh's own reason" {
  # A 403 is where SSO and scope rejections land; the code alone names none of
  # them.
  export GH_STUB_UNEXPECTED=1
  run branch_exists loft-sh/loft-enterprise release-4.11
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected status 403"* ]]
  [[ "$output" == *"SAML enforcement"* ]]
}

@test "main: a newline in the version cannot forge a workflow command in the notice" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="$(printf 'v4.11.3\n::error::FORGED')" INPUT_DRY_RUN="true" run main
  # Rejected by the gate, and the notice that would have echoed it never runs on
  # a flattened single line either way.
  [ "$status" -ne 0 ]
  [[ "${lines[0]}" != "::error::FORGED" ]]
}

# ---- require_dispatchable: the trigger checks are scoped to `on:` ----

@test "require_dispatchable: a job's with: triggered_by does not satisfy the input declaration" {
  # The hole this closes: the workflow still passes triggered_by through to a
  # job, but no longer declares it, so `gh workflow run -f triggered_by=...`
  # 422s - after the tag exists.
  export GH_STUB_WF_TRIGGERED_BY_IN_JOB=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares no 'triggered_by' input"* ]]
}

@test "require_dispatchable: the bare scalar on: workflow_dispatch form is accepted" {
  # Refusing it would block every cut on that line with a message telling the
  # operator to do a conversion they have already done.
  export GH_STUB_WF_SCALAR_ON=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "main: a newline in the version cannot forge a command through the validation error" {
  # validate_version quotes the value back, so flattening only at the notice left
  # the rejection path able to emit a second workflow command.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="$(printf 'v4.11.3\n::error::FORGED')" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  for l in "${lines[@]}"; do
    [[ "$l" != "::error::FORGED" ]]
  done
}

@test "main: a newline in the source-branch cannot forge a command through the routing error" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_SOURCE_BRANCH="$(printf 'main\n::error::FORGED')" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  for l in "${lines[@]}"; do
    [[ "$l" != "::error::FORGED" ]]
  done
}

# ---- the trigger check is anchored on the key, not the token ----

@test "require_dispatchable: a commented-out workflow_dispatch is refused" {
  # Parked during a code freeze: the token is in the file, the workflow is not
  # dispatchable, and tagging it strands the tag.
  export GH_STUB_WF_COMMENTED_OUT=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"no workflow_dispatch trigger"* ]]
}

@test "require_dispatchable: a comment merely mentioning the trigger does not count" {
  # A column-0 comment does not end the on: block, so an unfiltered block would
  # let this release-triggered workflow pass.
  export GH_STUB_WF_COMMENT_MENTIONS=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"no workflow_dispatch trigger"* ]]
}

@test "require_dispatchable: the block-sequence trigger form is accepted" {
  export GH_STUB_WF_SEQUENCE_ON=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "main: a newline in dry-run cannot forge a command through the warning" {
  # The unrecognized-value warning quotes the input straight back.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="$(printf 'false\n::error::Release v9.9.9 published')" run main
  for l in "${lines[@]}"; do
    [[ "$l" != "::error::Release v9.9.9 published" ]]
  done
  # Fail-closed: an unrecognized value stays in dry-run.
  [[ "$output" == *"[dry-run]"* ]]
}

@test "require_dispatchable: the token inside an on: value is not the trigger" {
  # No comment involved, so this is the case only the key anchoring rejects: a
  # repository_dispatch type that happens to contain the word.
  export GH_STUB_WF_TOKEN_IN_VALUE=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"no workflow_dispatch trigger"* ]]
}

# ---- legal trigger spellings must not be false-rejected ----
#
# A false reject is the worse failure of the two this check can make: it blocks
# every cut on that line, real or dry-run, with a message telling the operator to
# do a conversion that is already done.

@test "require_dispatchable: a block sequence at the parent's indentation is accepted" {
  export GH_STUB_WF_SEQUENCE_FLUSH=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a trailing comment on a sequence trigger is accepted" {
  export GH_STUB_WF_TRAILING_COMMENT=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a trailing comment on a scalar trigger is accepted" {
  export GH_STUB_WF_SCALAR_TRAILING_COMMENT=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- require_dispatchable: the input checks are scoped to workflow_dispatch ----

@test "require_dispatchable: a triggered_by declared only under workflow_call is refused" {
  # The hole this closes: a release.yaml that is both callable and dispatchable
  # declares triggered_by for its CALLERS while the dispatch contract has none.
  # An on:-wide grep counted that as the declaration, so the preflight passed and
  # `gh workflow run -f triggered_by=...` 422'd after the tag existed.
  export GH_STUB_WF_TRIGGERED_BY_IN_CALL=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares no 'triggered_by' input"* ]]
  [[ "$output" == *"Nothing was tagged"* ]]
}

@test "require_dispatchable: the same workflow passes when no triggered_by is sent" {
  # A direct script invocation passes no input at all, so the missing dispatch
  # declaration cannot 422 - and refusing here would be a false rejection.
  export GH_STUB_WF_TRIGGERED_BY_IN_CALL=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a workflow_call sibling does not block a declared triggered_by" {
  # The other side of the scoping: narrowing to workflow_dispatch must not start
  # rejecting the callable-and-dispatchable shape that declares it in both.
  export GH_STUB_WF_TRIGGERED_BY_IN_BOTH=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- require_dispatchable: inputs the cut cannot satisfy ----

@test "require_dispatchable: a tab after required: still reads as required" {
  export GH_STUB_WF_REQUIRED_TAB=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"required workflow_dispatch input(s) with no default"*"(version)"* ]]
}

@test "require_dispatchable: a key named workflow_dispatch below the triggers is not one" {
  export GH_STUB_WF_NESTED_DISPATCH_KEY=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no workflow_dispatch trigger"* ]]
}

@test "require_dispatchable: a required input with no default is refused" {
  # The dispatch sends triggered_by and nothing else, so any OTHER required
  # input with no default answers "Required input not provided" - after the tag
  # exists, the same orphan this preflight exists to pre-empt.
  export GH_STUB_WF_REQUIRED_NO_DEFAULT=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"required workflow_dispatch input(s) with no default"* ]]
  [[ "$output" == *"(version)"* ]]
  [[ "$output" == *"Nothing was tagged"* ]]
}

@test "require_dispatchable: a required input WITH a default is accepted" {
  # The API fills a default in, so this line is dispatchable and refusing it
  # would block every cut on it.
  export GH_STUB_WF_REQUIRED_WITH_DEFAULT=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a comment mentioning true does not make an input required" {
  # `required: false  # true once the line converts`. Reading the value without
  # stripping the trailing comment first would reject a dispatchable line.
  export GH_STUB_WF_REQUIRED_IN_COMMENT=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: triggered_by itself is checked when the cut does not pass it" {
  # It is excluded from the unsatisfiable scan only because the dispatch sends
  # it. With TRIGGERED_BY empty nothing is sent, so a required-and-undefaulted
  # triggered_by 422s like any other input.
  export GH_STUB_WF_REQUIRED_NO_DEFAULT=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"required workflow_dispatch input(s) with no default"* ]]
}

@test "main: an unsatisfiable input is refused before the tag is created" {
  # The whole point of the preflight: no tag, no dispatch, nothing to clean up.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_REQUIRED_NO_DEFAULT=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"required workflow_dispatch input(s) with no default"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

# ---- require_dispatchable: flow style reads like block style ----

@test "require_dispatchable: a workflow that is not YAML is refused with yq's reason" {
  export GH_STUB_WF_BROKEN_YAML=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not YAML this preflight can parse"* ]]
  [[ "$output" == *"yq said:"*"did not find expected"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "require_dispatchable: an input name that cannot be quoted back is refused" {
  # A key carrying a newline must not reach an annotation, where it would start
  # a second workflow command.
  export GH_STUB_WF_BAD_INPUT_NAME=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"input names outside letters"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^::')" -eq 1 ]
}

@test "require_dispatchable: an integer input name is refused as a bad name, not as bad YAML" {
  export GH_STUB_WF_INT_INPUT=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"input names outside letters"* ]]
  [[ "$output" != *"not YAML"* ]]
}

@test "require_dispatchable: a merge key is refused, since GitHub would reject the file" {
  export GH_STUB_WF_MERGE_KEY=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge key (<<) or repeats a key"* ]]
  # yq's merge-anchor warning must not leak into the run log.
  [[ "$output" != *"level=WARN"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "require_dispatchable: a repeated key is refused" {
  export GH_STUB_WF_DUPLICATE_KEY=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"merge key (<<) or repeats a key"* ]]
}

@test "require_dispatchable: a quoted << key is not a merge key" {
  export GH_STUB_WF_QUOTED_MERGE_NAME=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- require_yq ----

# fake_yq <version output> - put a yq on PATH that reports that version.
fake_yq() {
  mkdir -p "${STUB_DIR}/fakeyq"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$1" >"${STUB_DIR}/fakeyq/yq"
  chmod +x "${STUB_DIR}/fakeyq/yq"
  PATH="${STUB_DIR}/fakeyq:${PATH}"
}

@test "require_yq: a current mikefarah yq passes" {
  fake_yq "yq (https://github.com/mikefarah/yq/) version v4.53.6"
  run require_yq
  [ "$status" -eq 0 ]
}

@test "require_yq: the oldest checked release passes" {
  fake_yq "yq (https://github.com/mikefarah/yq/) version v4.46.1"
  run require_yq
  [ "$status" -eq 0 ]
}

@test "require_yq: an older mikefarah yq is refused by version" {
  fake_yq "yq (https://github.com/mikefarah/yq/) version v4.44.6"
  run require_yq
  [ "$status" -ne 0 ]
  [[ "$output" == *"4.44.6 is on PATH"*"v4.46.1 or later"* ]]
}

@test "require_yq: the python yq wrapper is refused by name" {
  fake_yq "yq 3.4.3"
  run require_yq
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not mikefarah yq"*"yq 3.4.3"* ]]
}

@test "require_yq: a yq that cannot run is named as broken, not missing" {
  mkdir -p "${STUB_DIR}/fakeyq"
  printf '#!/usr/bin/env bash\necho "cannot execute binary file: Exec format error" >&2\nexit 126\n' >"${STUB_DIR}/fakeyq/yq"
  chmod +x "${STUB_DIR}/fakeyq/yq"
  PATH="${STUB_DIR}/fakeyq:${PATH}" run require_yq
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not run: cannot execute binary file"* ]]
  [[ "$output" != *"not on PATH"* ]]
}

@test "require_yq: no yq at all is refused" {
  mkdir -p "${STUB_DIR}/empty"
  PATH="${STUB_DIR}/empty" run require_yq
  [ "$status" -ne 0 ]
  [[ "$output" == *"yq is not on PATH"* ]]
}

@test "main: a missing yq stops the cut before any API call" {
  fake_yq "yq 3.4.3"
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not mikefarah yq"* ]]
  [ ! -s "${STUB_DIR}/contents" ]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "require_dispatchable: a flow-mapping on: block is read like a block one" {
  # `on: {workflow_dispatch: }` declares the trigger. With triggered_by being
  # passed, the one thing missing is that input, and that is what gets named.
  export GH_STUB_WF_FLOW_MAPPING=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares no 'triggered_by' input"* ]]
  [[ "$output" != *"no workflow_dispatch trigger"* ]]
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: inline workflow_dispatch inputs are read" {
  export GH_STUB_WF_DISPATCH_INLINE=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: flow-style inputs are read" {
  export GH_STUB_WF_INPUTS_INLINE=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: flow-style inputs on the workflow_call sibling are ignored" {
  # Only workflow_dispatch's own inputs are the dispatch contract.
  export GH_STUB_WF_CALL_INPUTS_INLINE=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- require_dispatchable: a description is prose, not declarations ----

@test "require_dispatchable: a default: line inside a description is not a default" {
  # Fail-open before the fix: the prose satisfied the default check on an input
  # that has none, so the 422 landed after the tag existed.
  export GH_STUB_WF_DEFAULT_IN_DESCRIPTION=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"required workflow_dispatch input(s) with no default"* ]]
  [[ "$output" == *"(version)"* ]]
}

@test "require_dispatchable: the same description with a real default is accepted" {
  # Skipping the block scalar must not cost the declaration that follows it.
  export GH_STUB_WF_DESCRIPTION_AND_DEFAULT=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- require_dispatchable: boolean and line-ending spellings ----

@test "require_dispatchable: required: TRUE is read as required" {
  # TRUE is the same boolean as true, so matching only the lowercase spelling
  # read this input as optional and let the dispatch 422 after the tag.
  export GH_STUB_WF_REQUIRED_UPPERCASE=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"required workflow_dispatch input(s) with no default"* ]]
}

@test "require_dispatchable: a CRLF release.yaml is read like any other" {
  # The trailing CR defeated the end-anchored key match while the un-anchored
  # trigger regex still matched, so a converted line was refused for an input it
  # declares.
  export GH_STUB_WF_CRLF=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- require_dispatchable: quoting is not a different workflow ----

@test "require_dispatchable: a quoted trigger in a block sequence is accepted" {
  export GH_STUB_WF_QUOTED_SEQUENCE=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a quoted bare scalar trigger is accepted" {
  export GH_STUB_WF_QUOTED_SCALAR=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a quoted trigger mapping key is accepted" {
  export GH_STUB_WF_QUOTED_KEY=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a quoted triggered_by input satisfies the declaration" {
  # Captured with its quotes attached, 'triggered_by' never matched the name the
  # dispatch passes, so the cut was refused for an input the workflow declares.
  export GH_STUB_WF_QUOTED_INPUT=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- require_dispatchable: gh's stderr is not the workflow ----

@test "require_dispatchable: a gh notice mid-body is not read as YAML" {
  # Merged into the body, a column-0 notice ends the `on:` block early and the
  # trigger under it vanishes - a converted line refused for a trigger it has.
  export GH_STUB_WF_STDERR_MIDSTREAM=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: an unreadable workflow still carries gh's reason" {
  # Separating stderr must not cost the diagnostic the failure branch needs.
  export GH_STUB_WF_UNREADABLE=1
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"Not Found"* ]]
}

# ---- the preflight and the tag see the same commit ----

@test "main: the workflow is read at the sha the tag is created on" {
  # Two reads of a moving ref let a push between them get tagged unvalidated.
  # The contents read must carry the resolved sha, not the branch name, and the
  # tag POST must carry that same sha.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  run grep -F 'ref=head-release-4.11' "${STUB_DIR}/contents"
  [ "$status" -eq 0 ]
  run grep -F 'sha=head-release-4.11' "${STUB_DIR}/calls"
  [ "$status" -eq 0 ]
}

@test "main: a dry-run reads the head it would tag" {
  # The preview names the commit rather than a placeholder, so the sha it prints
  # is the one the real cut would use.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"sha=head-release-4.11"* ]]
}

@test "main: a branch deleted before the preflight aborts before any read of it" {
  # The rc probe saw the branch, and the head read that follows does not, so
  # the workflow is never read at a commit nobody resolved.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_HEAD_MISSING=1
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents"
  INPUT_VERSION="v4.11.3-rc.1" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"branch 'release-4.11' not found"* ]]
  ! grep -q 'contents/' "${STUB_DIR}/contents"
}

# ---- require_dispatchable: a multi-line default is still a default ----

@test "require_dispatchable: a multi-line default satisfies a required input" {
  # The block-scalar skip that keeps a description from faking a default must
  # not swallow a real `default: |`. Refusing here blocks every cut on the line.
  export GH_STUB_WF_MULTILINE_DEFAULT=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a folded default satisfies a required input" {
  export GH_STUB_WF_FOLDED_DEFAULT=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- require_dispatchable: flow sequences ----

@test "require_dispatchable: a multi-line flow sequence lists its triggers" {
  # Its workflow_dispatch has no inputs, so passing triggered_by is what fails.
  export GH_STUB_WF_MULTILINE_FLOW_SEQ=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares no 'triggered_by' input"* ]]
  [[ "$output" != *"has no workflow_dispatch trigger"* ]]
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: the one-line inline list is still a trigger" {
  # The flow-sequence refusal is checked after dispatch_re precisely so this
  # legal spelling keeps working.
  export GH_STUB_WF_INLINE_LIST=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

# ---- source-branch is shape-validated before it reaches a URL ----

@test "validate_branch: a query marker is rejected" {
  # gh reads `?` as the start of a query string, so `main?` resolved to main at
  # every endpoint while reading as "not main" to the feature-branch guard.
  run validate_branch "main?"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid branch name"* ]]
}

@test "validate_branch: ordinary branch names pass" {
  run validate_branch "engplat-406/private-nodes"
  [ "$status" -eq 0 ]
  run validate_branch "release-4.11"
  [ "$status" -eq 0 ]
  run validate_branch "main"
  [ "$status" -eq 0 ]
}

@test "validate_branch: traversal, leading dash and leading dot are rejected" {
  run validate_branch "../etc"
  [ "$status" -ne 0 ]
  run validate_branch "-flag"
  [ "$status" -ne 0 ]
  run validate_branch ".hidden"
  [ "$status" -ne 0 ]
  run validate_branch "trailing/"
  [ "$status" -ne 0 ]
}

@test "validate_branch: HEAD, other pseudo-refs and refs/ paths are rejected" {
  # Each resolves in git, or names a ref outright, rather than naming a branch.
  for b in HEAD FETCH_HEAD ORIG_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_HEAD REBASE_HEAD AUTO_MERGE refs/heads/main refs/tags/v1.2.3; do
    run validate_branch "$b"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid branch name"* ]]
  done
}

@test "validate_branch: names that only contain HEAD or refs pass" {
  for b in feature/HEAD HEADS head feature/refs/x release/refs-fix AHEAD OVERHEAD FIX_HEAD; do
    run validate_branch "$b"
    [ "$status" -eq 0 ]
  done
}

@test "main: a -next source-branch of HEAD is refused before any API call" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.12.0-next.1" INPUT_SOURCE_BRANCH="HEAD" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid branch name"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "main: a query marker cannot smuggle main past the feature-branch guard" {
  # The whole point: -next is cut from a short-lived branch, and `main?` would
  # otherwise tag the default branch.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.12.0-next.internal.1" INPUT_SOURCE_BRANCH="main?" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid branch name"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

# ---- require_dispatchable: nothing else may build off the tag ----

@test "require_dispatchable: a half-converted line still on push tags is refused" {
  # The dispatcher premise is that the tag feeds ONE build. Left in place, the
  # old tag trigger starts a second one the moment create_tag runs, and the two
  # race to create the same release.
  export GH_STUB_WF_PUSH_TAGS=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (push)"* ]]
  [[ "$output" == *"Nothing was tagged"* ]]
}

@test "require_dispatchable: an unfiltered push trigger is refused" {
  export GH_STUB_WF_PUSH_BARE=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (push)"* ]]
}

@test "require_dispatchable: a push filtered to branches is refused too" {
  # It never fires for a tag, but telling which filters do is GitHub's rule to
  # keep, not this preflight's. A release workflow has no reason to build on
  # push, so every trigger but a dispatch is refused.
  export GH_STUB_WF_PUSH_BRANCHES=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (push)"* ]]
}

@test "require_dispatchable: workflow_call next to workflow_dispatch is accepted" {
  # workflow_call only runs when another workflow calls it, so it cannot start a
  # build of the tag on its own.
  export GH_STUB_WF_TRIGGERED_BY_IN_BOTH=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: any other trigger is refused, filters or not" {
  TRIGGERED_BY=""
  export GH_STUB_WF_BODY=$'on:\n  workflow_dispatch:\n  schedule:\n    - cron: "0 0 * * *"\n  pull_request:\n'
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch ("*"pull_request"*")"* ]]
  [[ "$output" == *"schedule"* ]]
  [[ "$output" == *"Nothing was tagged"* ]]
}

@test "main: a half-converted line is refused before the tag is created" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_PUSH_TAGS=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (push)"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

# ---- the push probe reads triggers, not anything named like one ----

@test "require_dispatchable: an input named push is not a push trigger" {
  # The false rejection this closes: the cut was refused over a push trigger the
  # file does not have.
  export GH_STUB_WF_INPUT_NAMED_PUSH=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: an input named push cannot shadow a real one" {
  # The other direction: read at any depth, the input would answer first and
  # hide the real push trigger behind it.
  export GH_STUB_WF_INPUT_PUSH_SHADOWS=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (push)"* ]]
}

@test "require_dispatchable: the list spellings of a push trigger are still refused" {
  # Each carries no filter at all, so it fires for every ref. Depth-pinning the
  # list reading must not cost the detection it was pinned to make honest.
  TRIGGERED_BY="someone"
  local flag
  for flag in GH_STUB_WF_SEQ_PUSH GH_STUB_WF_SEQ_PUSH_FLUSH GH_STUB_WF_INLINE_PUSH; do
    export "${flag}=1"
    run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
    [ "$status" -ne 0 ]
    [[ "$output" == *"triggers on more than workflow_dispatch (push)"* ]]
    unset "$flag"
  done
}

@test "require_dispatchable: a choice option named push is not a push trigger" {
  # The sequence half of the same false rejection an input named `push` caused:
  # read at any depth, `- push` under `options:` refused the cut outright.
  export GH_STUB_WF_OPTION_NAMED_PUSH=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: a line still triggering on release is refused" {
  # The half-converted shape the no-trigger refusal cannot see: workflow_dispatch
  # is there, so the file has a trigger - and `release: created` fires again the
  # moment the dispatched build publishes, racing it for the same release.
  export GH_STUB_WF_RELEASE_AND_DISPATCH=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (release)"* ]]
  [[ "$output" == *"Nothing was tagged"* ]]
}

@test "require_dispatchable: a line still triggering on create is refused" {
  # `create` fires on the tag itself and takes no filter that would stop it.
  export GH_STUB_WF_CREATE_AND_DISPATCH=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (create)"* ]]
}

@test "require_dispatchable: an input named release is not a release trigger" {
  export GH_STUB_WF_INPUT_NAMED_RELEASE=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "main: a line still triggering on release is refused before the tag is created" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_RELEASE_AND_DISPATCH=1
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (release)"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "require_dispatchable: a flow sequence is read whichever trigger comes first" {
  # push sits on the second line of the list and is unfiltered there.
  export GH_STUB_WF_FLOW_SEQ_DISPATCH_FIRST=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"triggers on more than workflow_dispatch (push)"* ]]
}

@test "require_dispatchable: the one-line inline list is still read normally" {
  # The guard above moved ahead of the trigger check; the closed bracket is what
  # keeps it off this shape.
  export GH_STUB_WF_INLINE_LIST=1
  TRIGGERED_BY=""
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -eq 0 ]
}

@test "require_dispatchable: an inline required input with no default is refused" {
  # `version: {required: true}` is as required as the block spelling, and the
  # dispatch does not pass it, so it 422s after the tag exists.
  export GH_STUB_WF_INPUT_INLINE=1
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"required workflow_dispatch input(s) with no default"*"(version)"* ]]
  [[ "$output" == *"Nothing was tagged"* ]]
}


@test "validate_branch: a dot segment is rejected" {
  # `main/.` passes is_feature_branch as "not main", and a hop that normalizes
  # the URL path would read it as main.
  run validate_branch "main/."
  [ "$status" -ne 0 ]
  run validate_branch "x/./main"
  [ "$status" -ne 0 ]
  run validate_branch "feature/.hidden"
  [ "$status" -ne 0 ]
  run validate_branch "feature/v1.2"
  [ "$status" -eq 0 ]
}

@test "main: a -next source-branch with a dot segment never reaches the API" {
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls.log"
  INPUT_VERSION="v4.12.0-next.1" INPUT_SOURCE_BRANCH="main/." INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid branch name"* ]]
  [ ! -s "$GH_STUB_CALL_LOG" ]
}

@test "require_dispatchable: a required input with a bare default: is refused" {
  # A bare `default:` is null, and the API cannot fill a required input from it.
  export GH_STUB_WF_BODY=$'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        required: true\n        default:\n      triggered_by:\n        type: string'
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"(version)"* ]]
}

@test "require_dispatchable: a required input with an empty-string default is refused" {
  # An empty value may itself read as not provided, so it is not counted.
  export GH_STUB_WF_BODY=$'on:\n  workflow_dispatch:\n    inputs:\n      version:\n        required: true\n        default: ""\n      triggered_by:\n        type: string'
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"(version)"* ]]
}

@test "require_dispatchable: a differently cased triggered_by is named" {
  export GH_STUB_WF_BODY=$'on:\n  workflow_dispatch:\n    inputs:\n      Triggered_By:\n        type: string'
  TRIGGERED_BY="someone"
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares 'Triggered_By'"* ]]
  [[ "$output" == *"Rename the input to 'triggered_by'"* ]]
}

README_URL="https://github.com/loft-sh/github-actions/blob/platform-release/v1/.github/actions/platform-release/README.md"
INSPECT="Inspect: gh run list --repo loft-sh/loft-enterprise --workflow release.yaml --limit 1000 --branch v4.11.3, and again with --branch refs/tags/v4.11.3"

# no_advice <output> - whether the refusal left what to do next to the README.
# Whether waiting, cancelling, deleting or publishing is safe depends on what a
# running build does next, which the cut cannot see.
no_advice() {
  [[ "$1" != *"Wait for"* && "$1" != *"re-run th"* && "$1" != *"publishing again"* \
    && "$1" != *"delete it"* && "$1" != *"cancel it"* && "$1" != *"cancel them"* \
    && "$1" != *"-X DELETE"* && "$1" != *"-X PATCH"* && "$1" != *"gh run cancel"* \
    && "$1" != *"promote-release"* && "$1" != *"may have shipped"* && "$1" != *"as it shipped"* ]]
}

@test "main: a draft release for the version is a hard error" {
  # releases/tags/ answers only for published releases, so a draft is found by
  # listing.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::refusing to cut v4.11.3 in loft-sh/loft-enterprise: a draft release for v4.11.3 exists. Nothing was tagged. Read the steps before deleting or publishing a draft or cancelling a run: ${README_URL}#draft-releases"* ]]
  [[ "$output" == *"::error::What the cut saw for v4.11.3 in loft-sh/loft-enterprise: tag v4.11.3 does not exist. Drafts by id: 201 (no publish time). ${INSPECT}"* ]]
  no_advice "$output"
  [[ "$output" != *"[dry-run] gh api -X POST"* ]]
}

@test "main: a draft release blocks the resume of an existing tag too" {
  # A second build beside the draft would leave two drafts for one version.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a draft release for v4.11.3 exists. Nothing was dispatched."* ]]
  [[ "$output" == *"tag v4.11.3 points at ${STUB_TAG_COMMIT}. Drafts by id: 201 (no publish time). Inspect:"* ]]
  [[ "$output" != *"Passed release.yaml runs"* && "$output" != *"Still going"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: several drafts are each named by id" {
  # gh release delete by tag cannot pick between drafts of one version.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3 loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": 2 draft releases for v4.11.3 exist. Nothing was dispatched."* ]]
  [[ "$output" == *"Drafts by id: 201 (no publish time), 202 (no publish time)."* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a draft and a shipped draft are told apart by publish time" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3 loft-sh/loft-enterprise:v4.11.3@shipped"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  # Published first, whatever order GitHub lists them in.
  [[ "$output" == *"Drafts by id: 202 (published 2026-01-01T00:00:00Z), 201 (no publish time)."* ]]
  no_advice "$output"
}

@test "main: a shipped draft is named even behind many that never shipped" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  local drafts="" i
  for i in 1 2 3 4 5 6; do drafts+="loft-sh/loft-enterprise:v4.11.3 "; done
  export GH_STUB_DRAFTS="${drafts}loft-sh/loft-enterprise:v4.11.3@shipped"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Drafts by id: 207 (published 2026-01-01T00:00:00Z), 201 (no publish time)"*", and 2 more. Inspect:"* ]]
}

@test "main: a draft beside a running build names both" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:in_progress:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a draft release for v4.11.3 exists; a release.yaml run for v4.11.3 is still going. Nothing was dispatched. Read the steps before deleting or publishing a draft or cancelling a run: ${README_URL}#draft-releases"* ]]
  [[ "$output" == *"Drafts by id: 201 (no publish time). Still going: runs 1 (in_progress). Inspect:"* ]]
  no_advice "$output"
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: every running build is named, not just the first" {
  # Cancelling or waiting on one would leave the others to ship the version.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:in_progress:null ${STUB_TAG_COMMIT}:completed:failure ${STUB_TAG_COMMIT}:queued:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": 2 release.yaml runs for v4.11.3 are still going. Nothing was dispatched. Steps: ${README_URL}#partial-failure-recovery"* ]]
  [[ "$output" == *"Still going: runs 3 (queued), 1 (in_progress)."* ]]
  [[ "$output" != *"Drafts by id"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a draft with its tag gone beside a running build says the tag is gone" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:in_progress:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is still going. Nothing was tagged."* ]]
  [[ "$output" == *": tag v4.11.3 does not exist. Drafts by id: 201 (no publish time). Still going: runs 1 (in_progress)."* ]]
  [[ "$output" != *"[dry-run] gh api -X POST"* ]]
}

@test "main: a passed build with a draft names the commit it built" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a draft release for v4.11.3 exists; a release.yaml run at tag v4.11.3 already passed, but there is no published release. Nothing was dispatched. Read the steps"*"#draft-releases"* ]]
  [[ "$output" == *"Drafts by id: 201 (no publish time). Passed release.yaml runs built ${STUB_TAG_COMMIT}. Inspect:"* ]]
  no_advice "$output"
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a build running beside a passed one at the tag reports both" {
  # With no draft, the pass alone still refuses: waiting on the live build and
  # re-running would only be refused again.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success ${STUB_TAG_COMMIT}:in_progress:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a release.yaml run for v4.11.3 is still going; a release.yaml run at tag v4.11.3 already passed, but there is no published release. Nothing was dispatched."* ]]
  [[ "$output" == *"Still going: runs 2 (in_progress). Passed release.yaml runs built ${STUB_TAG_COMMIT}."* ]]
  no_advice "$output"
}

@test "main: a re-cut build beside an older passed one names both commits" {
  # The version was pulled and re-cut at another commit, so the older pass is
  # not a sign the running build repeats a release. Only the operator knows
  # which case it is, so the cut names both commits and the tag.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="2222222222222222222222222222222222222222:completed:success ${STUB_TAG_COMMIT}:in_progress:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a draft release for v4.11.3 exists; a release.yaml run for v4.11.3 is still going. Nothing was dispatched."* ]]
  [[ "$output" == *"tag v4.11.3 points at ${STUB_TAG_COMMIT}. Drafts by id: 201 (no publish time). Still going: runs 2 (in_progress). Passed release.yaml runs built 2222222222222222222222222222222222222222."* ]]
  [[ "$output" != *"already passed"* ]]
  no_advice "$output"
}

@test "main: a running re-run whose first attempt passed counts the pass" {
  # The list shows only the live attempt, and the one before it may have
  # published.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:in_progress:null:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed, but there is no published release"* ]]
  [[ "$output" == *"Still going: runs 1 (in_progress). Passed release.yaml runs built ${STUB_TAG_COMMIT}."* ]]
}

@test "main: a shipped draft with no run on record is named with its publish time" {
  # Old run records can be gone; the publish time on the draft is enough.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3@shipped"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Drafts by id: 201 (published 2026-01-01T00:00:00Z). Inspect:"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a shipped draft beside a passed build of another commit names both" {
  # The tag was moved after shipping, so the operator needs the commit it
  # shipped from to put the tag back before publishing.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3@shipped"
  export GH_STUB_RUNS="2222222222222222222222222222222222222222:completed:success ${STUB_TAG_COMMIT}:completed:failure"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag v4.11.3 points at ${STUB_TAG_COMMIT}. Drafts by id: 201 (published 2026-01-01T00:00:00Z). Passed release.yaml runs built 2222222222222222222222222222222222222222."* ]]
}

@test "main: an attempt that passed before a failed re-run still counts as passed" {
  # The run list shows only the latest attempt.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure:failure,success"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed, but there is no published release"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
  grep -q 'actions/runs/1/attempts/1$' "$GH_STUB_CONTENTS_LOG"
  grep -q 'actions/runs/1/attempts/2$' "$GH_STUB_CONTENTS_LOG"
}

@test "main: a re-run whose earlier attempts all failed is resumed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure:cancelled"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-dispatch"* ]]
}

@test "main: earlier attempts are not read when they cannot change the cut" {
  # Nothing else refuses, and neither run is at the tag, so a pass in either
  # would not block. A call each would only slow the cut and add a way to fail.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RUNS="2222222222222222222222222222222222222222:completed:failure:failure,failure,failure"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-dispatch"* ]]
  ! grep -q '/attempts/' "$GH_STUB_CONTENTS_LOG"
}

@test "main: earlier attempts of another commit are not read on a resume" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="2222222222222222222222222222222222222222:completed:failure:success"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-dispatch"* ]]
  ! grep -q '/attempts/' "$GH_STUB_CONTENTS_LOG"
}

@test "main: an earlier attempt that cannot be read aborts instead of reading as failed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure:success"
  export GH_STUB_ATTEMPTS_FAIL=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read every attempt of release.yaml run 1 for v4.11.3"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a build that publishes between the reads is seen as published" {
  # Runs are read before releases, so a release listed after the runs is final.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  [[ "$(grep -m1 -E '/releases\?|/runs\?' "$GH_STUB_CONTENTS_LOG")" == *"workflows/release.yaml/runs?"* ]]
  grep -q '/releases?' "$GH_STUB_CONTENTS_LOG"
}

@test "main: a running build on a later page of the runs still blocks the resume" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure ${STUB_TAG_COMMIT}:in_progress:null"
  export GH_STUB_RUNS_PAGE_SIZE=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Still going: runs 2 (in_progress)."* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a passed build on a later page of the runs still blocks the resume" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure ${STUB_TAG_COMMIT}:completed:success"
  export GH_STUB_RUNS_PAGE_SIZE=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

# stub_failed_reruns_at_tag <n> - <n> failed re-runs of the tagged commit, each
# with a first attempt that passed.
stub_failed_reruns_at_tag() {
  local runs="" i
  for i in $(seq "$1"); do runs+="${STUB_TAG_COMMIT}:completed:failure:success "; done
  export GH_STUB_RUNS="$runs"
}

# A gh message far past the 300 characters a quoted cause is cut at.
LONG_GH_ERR="gh:$(printf ' Resource protected by organization SAML enforcement.%.0s' {1..40})"

# fits_annotation <output> - whether every error line stays under GitHub's
# ~1273-byte annotation cutoff even for the longest tag form,
# v4.13.0-next.internal.1, which is 16 bytes longer than the v4.11.3 these
# tests cut.
fits_annotation() {
  local line repeats
  grep -q '^::error::' <<<"$1" || return 1
  while IFS= read -r line; do
    repeats="$(grep -o 'v4\.11\.3' <<<"$line" | wc -l || true)"
    (( ${#line} + repeats * 16 < 1273 )) || return 1
  done < <(grep '^::error::' <<<"$1")
}

@test "main: every refusal line fits in one annotation" {
  # GitHub cuts an annotation at about 1273 bytes, and the pointer to the steps
  # comes last. Real release ids have 9 digits, run ids 11, and action_required
  # is the longest status a live run can have.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFT_ID_BASE=987654300 GH_STUB_RUN_ID_BASE=98765432100
  local shipped_drafts="" plain_drafts="" passed="" live="" i
  for i in $(seq 40); do
    shipped_drafts+="loft-sh/loft-enterprise:v4.11.3@shipped loft-sh/loft-enterprise:v4.11.3 "
    plain_drafts+="loft-sh/loft-enterprise:v4.11.3 loft-sh/loft-enterprise:v4.11.3 "
  done
  for i in 1 2 3 4 5 6 7 8 9; do passed+="${i}$(printf '%039d' 0):completed:success "; done
  for i in 1 2 3 4 5 6 7 8; do live+="${STUB_TAG_COMMIT}:action_required:null "; done
  local at_tag="${STUB_TAG_COMMIT}:completed:success"
  local releases drafts tags runs
  for releases in "" "loft-sh/loft-enterprise:v4.11.3"; do
    for drafts in "$shipped_drafts" "$plain_drafts"; do
      for tags in "" "loft-sh/loft-enterprise:v4.11.3"; do
        for runs in "${passed}${live}" "${passed}${at_tag}" "$passed"; do
          export GH_STUB_RELEASES="$releases" GH_STUB_DRAFTS="$drafts" GH_STUB_TAGS="$tags" GH_STUB_RUNS="$runs"
          INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
          [ "$status" -ne 0 ]
          fits_annotation "$output"
          if [[ "$drafts" == "$shipped_drafts" ]]; then
            [[ "$output" == *"and 75 more, 35 of them published."*"Passed release.yaml runs built "*", and "*" more. Inspect:"* ]]
          else
            [[ "$output" == *"and 75 more."*"Inspect:"* ]]
          fi
          [[ "$output" == *"runs 98765432117 (action_required), "*", and 3 more."* || "$runs" != *action_required* ]]
          no_advice "$output"
        done
      done
    done
  done
}

@test "main: a draft and a running build beside the published release are named" {
  # A draft or live build beside the release may be a second build of the
  # version on its way to publishing it twice.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3@shipped loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success ${STUB_TAG_COMMIT}:in_progress:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": release v4.11.3 already exists; 2 draft releases for v4.11.3 exist; a release.yaml run for v4.11.3 is still going. Nothing was dispatched."*"#draft-releases"* ]]
  [[ "$output" == *"Drafts by id: 201 (published 2026-01-01T00:00:00Z), 202 (no publish time). Still going: runs 2 (in_progress). Passed release.yaml runs built ${STUB_TAG_COMMIT}. Inspect:"* ]]
  [[ "$output" != *"already passed"* ]]
  no_advice "$output"
}

@test "main: a published release with nothing else beside it is only the double-cut guard" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::release v4.11.3 already exists in loft-sh/loft-enterprise. Refusing to re-cut (double-cut guard)."* ]]
  [[ "$output" != *"What the cut saw"* && "$output" != *"#draft-releases"* ]]
  ! grep -q '/git/ref/' "$GH_STUB_CONTENTS_LOG"
}

@test "main: a draft listed twice across pages is counted once" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RELEASES_REPEAT=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a draft release for v4.11.3 exists."* ]]
  [[ "$output" == *"Drafts by id: 201 (no publish time). Inspect:"* ]]
}

@test "main: a pass at the tag still reads the earlier attempts of other re-runs" {
  # The cut refuses on the pass alone, so the other commit's hidden pass is
  # one of the facts it reports.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success 2222222222222222222222222222222222222222:completed:failure:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Passed release.yaml runs built 2222222222222222222222222222222222222222, ${STUB_TAG_COMMIT}."* ]]
}

@test "main: an unreadable earlier attempt does not hide a refusal that stands anyway" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:in_progress:null:success"
  export GH_STUB_ATTEMPTS_FAIL=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a draft release for v4.11.3 exists; a release.yaml run for v4.11.3 is still going."* ]]
  [[ "$output" == *"Drafts by id: 201 (no publish time). Still going: runs 1 (in_progress). Not every attempt could be read for runs 1. Inspect:"* ]]
  [[ "$output" != *"could not read every attempt"* ]]
}

@test "main: a published release is still the double-cut guard when the runs cannot be listed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS_FAILS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::release v4.11.3 already exists in loft-sh/loft-enterprise. Refusing to re-cut (double-cut guard). The release.yaml runs could not be listed, so a running or passed build is not ruled out. gh said: "*"dial tcp"* ]]
}

@test "main: drafts are still named when the runs cannot be listed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3@shipped"
  export GH_STUB_RUNS_FAILS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a draft release for v4.11.3 exists. Nothing was dispatched."*"#draft-releases"* ]]
  [[ "$output" == *"Drafts by id: 201 (published 2026-01-01T00:00:00Z). The release.yaml runs could not be listed, so a running or passed build is not ruled out. gh said: "*"dial tcp"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a tag that cannot be read does not hide a refusal that stands anyway" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3@shipped"
  export GH_STUB_TRANSIENT_TAGS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": a draft release for v4.11.3 exists. Nothing was dispatched."* ]]
  [[ "$output" == *"What the cut saw for v4.11.3 in loft-sh/loft-enterprise: tag v4.11.3 could not be read. Drafts by id: 201 (published 2026-01-01T00:00:00Z)."* ]]
}

@test "main: the README link follows the ref the action runs at" {
  export GITHUB_ACTION_REPOSITORY="loft-sh/github-actions" GITHUB_ACTION_REF="0123abcd"
  source "$SCRIPT"
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"https://github.com/loft-sh/github-actions/blob/0123abcd/.github/actions/platform-release/README.md#draft-releases"* ]]
}

@test "main: the README link stays at v1 for a ref from another repository" {
  export GITHUB_ACTION_REPOSITORY="someone/fork" GITHUB_ACTION_REF="0123abcd"
  source "$SCRIPT"
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"${README_URL}#draft-releases"* ]]
}

@test "main: more running builds than the cap name the newest" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  local runs="" i
  for i in $(seq 7); do runs+="${STUB_TAG_COMMIT}:in_progress:null "; done
  export GH_STUB_RUNS="$runs"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Still going: runs 7 (in_progress), 6 (in_progress), 5 (in_progress), 4 (in_progress), 3 (in_progress), and 2 more."* ]]
}

@test "main: earlier attempts are not read for a commit already known to have passed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success ${STUB_TAG_COMMIT}:completed:failure:failure"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed, but there is no published release"* ]]
  ! grep -q '/attempts/' "$GH_STUB_CONTENTS_LOG"
}

@test "main: earlier attempts stop being read once three newer passed commits are known" {
  # Runs 2 to 4 passed at three other commits, so run 1 cannot make the list.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="5555555555555555555555555555555555555555:completed:failure:success 2222222222222222222222222222222222222222:completed:success 3333333333333333333333333333333333333333:completed:success 6666666666666666666666666666666666666666:completed:success"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Passed release.yaml runs built 6666666666666666666666666666666666666666, 3333333333333333333333333333333333333333, 2222222222222222222222222222222222222222. 1 older run was not checked for a pass the run list does not show."* ]]
  ! grep -q '/attempts/' "$GH_STUB_CONTENTS_LOG"
}

@test "main: a tag that cannot be read still ends a cut nothing else refuses" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TRANSIENT_TAGS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to reach GitHub API for tag v4.11.3"* ]]
  [[ "$output" != *"refusing to cut"* && "$output" != *"stub-dispatch"* ]]
}

@test "main: an earlier attempt that fails outright is reported like a 404 once the cut refuses" {
  # A 404 is rare for an attempt below run_attempt; a failed request is not.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:in_progress:null:success"
  export GH_STUB_ATTEMPTS_FAIL=transient
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Still going: runs 1 (in_progress). Not every attempt could be read for runs 1."* ]]
}

@test "main: a pass found in an earlier attempt at the tag reads the other re-runs" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="2222222222222222222222222222222222222222:completed:failure:success ${STUB_TAG_COMMIT}:completed:failure:success 3333333333333333333333333333333333333333:completed:failure:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed, but there is no published release"* ]]
  [[ "$output" == *"Passed release.yaml runs built 3333333333333333333333333333333333333333, ${STUB_TAG_COMMIT}, 2222222222222222222222222222222222222222."* ]]
}

@test "main: a release published between two pages counts as published" {
  # The later, published copy of 201 wins over the draft one.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RELEASES_REPEAT=published
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::release v4.11.3 already exists in loft-sh/loft-enterprise. Refusing to re-cut (double-cut guard)."* ]]
  [[ "$output" != *"Drafts by id"* ]]
}

@test "main: an unreadable earlier attempt does not hide a pass in a later one" {
  # Attempt 1 cannot be read, attempt 2 passed, attempt 3 is the failed latest.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure:,success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed, but there is no published release"* ]]
  [[ "$output" == *"Passed release.yaml runs built ${STUB_TAG_COMMIT}."* ]]
}

@test "main: failed reads behind a refusal do not crowd it out of the annotations" {
  # GitHub shows at most ten error annotations per step.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_ATTEMPTS_FAIL=transient
  stub_failed_reruns_at_tag 12
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [ "$(grep -c '^::error::' <<<"$output")" -eq 3 ]
  [[ "$output" == *"Not every attempt could be read for runs 12, 11, 10, 9, 8, and 7 more."* ]]
  [[ "$output" == *"::error::Reads that failed while gathering those facts: failed to reach GitHub API for attempt 1 of run "*"gh said: gh: dial tcp: lookup api.github.com"* ]]
  fits_annotation "$output"
}

@test "main: a tag that does not lead to a commit is one fact, not a second refusal" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_TAG_ANNOTATED=1 GH_STUB_TAG_PEELS_TO=tree
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"What the cut saw for v4.11.3 in loft-sh/loft-enterprise: tag v4.11.3 in loft-sh/loft-enterprise does not lead to a commit (it ends at a tree ${STUB_TAG_COMMIT}), so no build can run from it. Drafts by id: 201"* ]]
  [ "$(grep -o 'does not lead to a commit' <<<"$output" | wc -l)" -eq 1 ]
  [[ "$output" != *"Re-run the cut"* ]]
  [ "$(grep -c '^::error::' <<<"$output")" -eq 2 ]
}

@test "main: an unreadable earlier attempt that decides the cut links the steps" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure:success"
  export GH_STUB_ATTEMPTS_FAIL=transient
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read every attempt of release.yaml run 1 for v4.11.3 in loft-sh/loft-enterprise, so the cut cannot tell whether it passed and published. Nothing was dispatched. Cause: failed to reach GitHub API for attempt 1 of run 1 in loft-sh/loft-enterprise (no HTTP status - DNS, rate-limit, or auth). Not treating as absent. gh said: gh: dial tcp: lookup api.github.com. Steps: ${README_URL}#partial-failure-recovery ${INSPECT}"* ]]
  [ "$(grep -c '^::error::' <<<"$output")" -eq 1 ]
}

@test "main: a long gh message is cut short so the steps still fit after it" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUN_ID_BASE=98765432100 GH_STUB_ATTEMPTS_FAIL=transient GH_STUB_ATTEMPTS_ERR="$LONG_GH_ERR"
  stub_failed_reruns_at_tag 12
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  local cause
  cause="$(capped_text "failed to reach GitHub API for attempt 1 of run 98765432112 in loft-sh/loft-enterprise (no HTTP status - DNS, rate-limit, or auth). Not treating as absent. gh said: ${LONG_GH_ERR}")"
  [[ "$cause" == *"..." ]]
  [[ "$output" == *"Cause: ${cause}. Steps: ${README_URL}#partial-failure-recovery ${INSPECT}"* ]]
  [[ "$output" != *"$LONG_GH_ERR"* ]]
  fits_annotation "$output"
}

@test "main: a long gh message behind a draft refusal is cut short" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUN_ID_BASE=98765432100 GH_STUB_ATTEMPTS_FAIL=transient GH_STUB_ATTEMPTS_ERR="$LONG_GH_ERR"
  stub_failed_reruns_at_tag 12
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  local cause
  cause="$(capped_text "failed to reach GitHub API for attempt 1 of run 98765432112 in loft-sh/loft-enterprise (no HTTP status - DNS, rate-limit, or auth). Not treating as absent. gh said: ${LONG_GH_ERR}")"
  [[ "$cause" == *"..." ]]
  [[ "$output" == *"Read the steps before deleting or publishing a draft or cancelling a run: ${README_URL}#draft-releases"* ]]
  grep -qFx "::error::Reads that failed while gathering those facts: ${cause}" <<<"$output"
  fits_annotation "$output"
}

@test "main: a long body with an HTTP status is cut short too" {
  # GitHub rejects a token not authorized for SAML SSO with a 403.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUN_ID_BASE=98765432100 GH_STUB_ATTEMPTS_FAIL=403 GH_STUB_ATTEMPTS_ERR="$LONG_GH_ERR"
  stub_failed_reruns_at_tag 12
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  local cause
  cause="$(capped_text "unexpected status 403 from GitHub API for attempt 1 of run 98765432112 in loft-sh/loft-enterprise. gh said: ${LONG_GH_ERR}")"
  [[ "$cause" == *"..." ]]
  [[ "$output" == *"Cause: ${cause}. Steps: ${README_URL}#partial-failure-recovery ${INSPECT}"* ]]
  fits_annotation "$output"
}

@test "main: a finished run listed with no conclusion is read again, not taken for a failure" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read every attempt of release.yaml run 1 for v4.11.3"*"Cause: attempt 1 of run 1 in loft-sh/loft-enterprise came back with no conclusion."* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a run listed with no conclusion whose attempt passed refuses the cut" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:null:failure" GH_STUB_LATEST_ATTEMPT=success
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"a release.yaml run at tag v4.11.3 already passed, but there is no published release"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
  grep -q 'actions/runs/1/attempts/2$' "$GH_STUB_CONTENTS_LOG"
}

@test "main: a run listed with no conclusion whose attempt failed is resumed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:null" GH_STUB_LATEST_ATTEMPT=failure
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-dispatch"* ]]
}

@test "main: an earlier attempt with no conclusion is not read as a failure" {
  # A finished attempt always has one, so an empty answer could hide the pass.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure:none"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read every attempt of release.yaml run 1"*"Cause: attempt 1 of run 1 in loft-sh/loft-enterprise came back with no conclusion."* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: the cause quoted for failed attempt reads is from a run listed as unread" {
  # Run 1's first read fails but its second attempt passed, so it is not unread.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure:none,success 2222222222222222222222222222222222222222:completed:failure:,"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Not every attempt could be read for runs 2."* ]]
  [[ "$output" == *"Reads that failed while gathering those facts: GitHub answered 404 for attempt 1 of run 2 in loft-sh/loft-enterprise"* ]]
  [[ "$output" != *"no conclusion"* ]]
}

@test "main: the tag is read once, so its existence and commit come from one answer" {
  # A second read could find the tag gone after the first found it.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents.log"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *": tag v4.11.3 points at ${STUB_TAG_COMMIT}."* ]]
  [ "$(grep -c '/git/ref/tags/v4.11.3$' "$GH_STUB_CONTENTS_LOG")" -eq 1 ]
}

@test "main: a draft for another version does not block the cut" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3-rc.1 loft-sh/loft-enterprise:v4.11.30"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=refs/tags/v4.11.3"* ]]
}

@test "main: a failed release listing aborts instead of reading as no draft" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TRANSIENT_DRAFTS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list releases"* ]]
  [[ "$output" == *"Not treating as absent"* ]]
  [[ "$output" == *"dial tcp"* ]]
  [[ "$output" != *"[dry-run] gh api -X POST"* ]]
}

# ---- double-cut listing and token permissions ----

@test "main: a draft on a later page of the release list is still found" {
  # Two published releases fill the first stub page, so the draft is only seen
  # if the guard pages.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.1 loft-sh/loft-enterprise:v4.11.2"
  export GH_STUB_DRAFTS="loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"a draft release for v4.11.3 exists"* ]]
}

@test "main: a published release on a later page is still found" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.1 loft-sh/loft-enterprise:v4.11.2 loft-sh/loft-enterprise:v4.11.3"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release v4.11.3 already exists"* ]]
}

@test "main: a token that cannot push is refused before any branch is read" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_PUSH_PERM=false
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot push to it"* ]]
  [[ "$output" != *"[dry-run]"* ]]
}

@test "main: a token with no reported permissions warns and carries on" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_PUSH_PERM=absent
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::GitHub reported no permissions"* ]]
  [[ "$output" == *"ref=refs/tags/v4.11.3"* ]]
}

# ---- workflow state, unreadable keys, and the tag-first double-cut probe ----

@test "main: a disabled release workflow is refused before anything is tagged" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_STATE=disabled_manually
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release.yaml in loft-sh/loft-enterprise is disabled_manually, not active"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "main: a release workflow GitHub does not list is refused in dry-run too" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_WF_STATE=missing
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub does not list release.yaml as a workflow"* ]]
  [[ "$output" != *"[dry-run]"* ]]
}

@test "require_dispatchable: a trigger that is not a GitHub event is refused" {
  export GH_STUB_WF_BODY=$'on:\n  Push:\n    tags: ["v*"]\n  workflow_dispatch:\n    inputs:\n      triggered_by:\n        type: string\n'
  TRIGGERED_BY=someone run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"whose name is not a GitHub event"* ]]
}

@test "require_dispatchable: a non-string trigger in the list form is refused" {
  export GH_STUB_WF_BODY=$'on: [workflow_dispatch, 3]\n'
  run require_dispatchable loft-sh/loft-enterprise release-4.11 release.yaml v4.11.3
  [ "$status" -ne 0 ]
  [[ "$output" == *"whose name is not a GitHub event"* ]]
}

@test "main: a published release is found by the listing alone" {
  # The listing already returns published releases, so the singular
  # releases/tags/ probe is not read as well.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release v4.11.3 already exists"* ]]
  ! grep -q 'releases/tags/' "${STUB_DIR}/contents"
}

# ---- resuming an interrupted cut ----

@test "main: a real resume dispatches at the existing tag without tagging again" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  TRIGGERED_BY="someone" INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched release.yaml in loft-sh/loft-enterprise at v4.11.3"* ]]
  [[ "$output" == *"--ref refs/tags/v4.11.3 -f triggered_by=someone"* ]]
  [[ "$output" != *"created tag"* ]]
  [ ! -s "${STUB_DIR}/calls" ]
}

@test "main: a resume reads release.yaml at the tagged commit, not the branch head" {
  # The dispatch runs the tagged commit's release.yaml, so that is the one the
  # preflight has to check.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  grep -q "contents/.github/workflows/release.yaml?ref=${STUB_TAG_COMMIT}" "${STUB_DIR}/contents"
  ! grep -q "ref=head-release-4.11" "${STUB_DIR}/contents"
}

@test "main: a resume after failed and cancelled builds dispatches again" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure ${STUB_TAG_COMMIT}:completed:cancelled"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming at the dispatch"* ]]
  [[ "$output" == *"dispatched release.yaml in loft-sh/loft-enterprise at v4.11.3"* ]]
}

@test "main: a build still running at the tag is not dispatched again" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure ${STUB_TAG_COMMIT}:in_progress:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Still going: runs 2 (in_progress)."* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a build still running from another commit also blocks the resume" {
  # The tag was moved under a running build. A second build would race it.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="3333333333333333333333333333333333333333:queued:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Still going: runs 1 (queued)."* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a passed build with no release is refused, not rebuilt" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::refusing to cut v4.11.3 in loft-sh/loft-enterprise: a release.yaml run at tag v4.11.3 already passed, but there is no published release. Nothing was dispatched. Steps: ${README_URL}#partial-failure-recovery"* ]]
  [[ "$output" == *"Passed release.yaml runs built ${STUB_TAG_COMMIT}."* ]]
  [[ "$output" != *"#draft-releases"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a passed build of an earlier commit under the tag name does not block the resume" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="3333333333333333333333333333333333333333:completed:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched release.yaml in loft-sh/loft-enterprise at v4.11.3"* ]]
}

@test "main: an annotated tag is peeled before its runs are matched" {
  # Runs report the peeled commit, so matching the tag object would miss the
  # passed build and dispatch a second one.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_TAG_ANNOTATED=1
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed"* ]]
}

@test "main: a tag pointing at another tag is peeled down to the commit" {
  # One level of peeling would match runs against the inner tag object, miss
  # the passed build and dispatch a second one.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_TAG_ANNOTATED=1
  export GH_STUB_TAG_NESTED=1
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed"* ]]
  grep -q "git/tags/${STUB_TAG_OBJECT2}" "${STUB_DIR}/contents"
}

@test "main: a nested tag resumes from the commit it leads to" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_TAG_ANNOTATED=1
  export GH_STUB_TAG_NESTED=1
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists at ${STUB_TAG_COMMIT}"* ]]
  grep -q "contents/.github/workflows/release.yaml?ref=${STUB_TAG_COMMIT}" "${STUB_DIR}/contents"
}

@test "main: a tag that leads to a tree, not a commit, is refused" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_TAG_ANNOTATED=1
  export GH_STUB_TAG_PEELS_TO=tree
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not lead to a commit (it ends at a tree ${STUB_TAG_COMMIT})"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a tag whose commit cannot be read is refused" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_TAG_NO_SHA=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"the commit it points at could not be resolved"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a failed run listing aborts instead of reading as no build" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS_FAILS=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list release.yaml runs at v4.11.3"* ]]
  [[ "$output" == *"dial tcp"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: an error-shaped run listing aborts instead of reading as no build" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS_BAD_SHAPE=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list release.yaml runs"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a resume refused by the preflight dispatches nothing" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_WF_NO_DISPATCH=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release.yaml at 'v4.11.3'"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

# ---- a tag deleted under a running build ----

@test "main: a missing tag with a build still running under its name is refused" {
  # Re-creating the tag at the branch head would start a second build of the
  # version from another commit.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RUNS="3333333333333333333333333333333333333333:in_progress:null"
  export GH_STUB_CALL_LOG="${STUB_DIR}/calls"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is still going. Nothing was tagged."* ]]
  [[ "$output" == *"tag v4.11.3 does not exist. Still going: runs 1 (in_progress)."* ]]
  [ ! -s "${STUB_DIR}/calls" ]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a missing tag with only finished builds under its name is cut again" {
  # Run records outlive the tag, so the delete-and-re-cut path stays open.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RUNS="3333333333333333333333333333333333333333:completed:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"created tag v4.11.3"* ]]
  [[ "$output" == *"dispatched release.yaml"* ]]
}

# ---- runs recorded under either head_branch spelling ----

@test "main: a running build recorded under refs/tags/<tag> still blocks the resume" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS_HEAD_BRANCH=full
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:in_progress:null"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Still going: runs 1 (in_progress)."* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a passed build recorded under refs/tags/<tag> still blocks the resume" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS_HEAD_BRANCH=full
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:success"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already passed"* ]]
}

# ---- waiting for the dispatched run to be listed ----

@test "main: a real cut waits until the dispatched run is listed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched release.yaml"* ]]
  [[ "$output" != *"was not listed"* ]]
}

@test "main: a dispatched run recorded under refs/tags/<tag> ends the wait too" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_RUNS_HEAD_BRANCH=full
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"was not listed"* ]]
}

@test "main: the wait keeps polling until the dispatched run is listed" {
  # setup allows 3 attempts. The run shows up on the last one.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DISPATCH_VISIBLE_AFTER=3
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"was not listed"* ]]
  [ "$(cat "${STUB_DIR}/dispatch_polls")" -eq 3 ]
}

@test "main: the wait stops at its attempt limit" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DISPATCH_VISIBLE_AFTER=4
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not listed"* ]]
  [ "$(cat "${STUB_DIR}/dispatch_polls")" -eq 3 ]
}

@test "main: a dispatched run that never shows up only warns" {
  # The build is queued, so failing the cut would be worse than the window.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_DISPATCH_INVISIBLE=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::release.yaml was dispatched"*"was not listed within 0s"* ]]
}

@test "main: on a resume, the failed runs already listed do not end the wait" {
  # Only a new run of the tagged commit proves the dispatch is visible.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_RUNS="${STUB_TAG_COMMIT}:completed:failure"
  export GH_STUB_DISPATCH_INVISIBLE=1
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not listed"* ]]
}

@test "main: a dry-run does not wait for a run" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_CONTENTS_LOG="${STUB_DIR}/contents"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"was not listed"* ]]
  [ "$(grep -c '/runs?' "${STUB_DIR}/contents")" -eq 2 ]
}

# ---- a resumed tag must be on the target branch ----

@test "main: a resume checks the tag commit against the target branch head" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_COMPARE_LOG="${STUB_DIR}/compare"
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  grep -qx "repos/loft-sh/loft-enterprise/compare/head-release-4.11...${STUB_TAG_COMMIT}" "${STUB_DIR}/compare"
}

@test "main: a stable tag that is not on its release branch is not resumed" {
  # The tag was made by hand on main, not on release-4.11.
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_COMPARE_STATUS=diverged
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not on release-4.11 (diverged)"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a tag ahead of its branch is not resumed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_COMPARE_STATUS=ahead
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not on release-4.11 (ahead)"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: an unexpected comparison status is refused" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:release-4.11"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.11.3"
  export GH_STUB_COMPARE_STATUS=weird
  INPUT_VERSION="v4.11.3" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected comparison status 'weird'"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

@test "main: a next tag re-run with another source-branch is not resumed" {
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:feature-b"
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.12.0-next.1"
  export GH_STUB_COMPARE_STATUS=diverged
  INPUT_VERSION="v4.12.0-next.1" INPUT_SOURCE_BRANCH="feature-b" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not on feature-b"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

# ---- a deleted source branch ----

@test "main: a next tag whose feature branch is gone still resumes" {
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.12.0-next.1"
  INPUT_VERSION="v4.12.0-next.1" INPUT_SOURCE_BRANCH="feature-a" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::branch 'feature-a' no longer exists"* ]]
  [[ "$output" == *"dispatched release.yaml in loft-sh/loft-enterprise at v4.12.0-next.1"* ]]
  [[ "$output" != *"created tag"* ]]
}

@test "main: a shipped next version whose branch is gone reports the double cut" {
  export GH_STUB_RELEASES="loft-sh/loft-enterprise:v4.12.0-next.1"
  INPUT_VERSION="v4.12.0-next.1" INPUT_SOURCE_BRANCH="feature-a" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to re-cut"* ]]
  [[ "$output" != *"not found"* ]]
}

@test "main: a fresh next cut from a missing branch is still refused" {
  INPUT_VERSION="v4.12.0-next.1" INPUT_SOURCE_BRANCH="feature-a" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"branch 'feature-a' not found"* ]]
}

@test "main: a resume whose line branch is gone is refused" {
  # A release-X.Y branch is never deleted, so its absence is not normal.
  export GH_STUB_TAGS="loft-sh/loft-enterprise:v4.12.0-rc.1"
  export GH_STUB_BRANCHES="loft-sh/loft-enterprise:main"
  export GH_STUB_HEAD_MISSING=1
  INPUT_VERSION="v4.12.0-rc.1" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"branch 'main' not found"* ]]
  [[ "$output" != *"stub-dispatch"* ]]
}

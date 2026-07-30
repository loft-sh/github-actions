#!/usr/bin/env bats
# Tests for vcluster-release.sh
#
# The routing helpers (parse_major_minor / derive_line / classify_era) are pure
# and network-free. branch_exists / guard / create_tag / dispatch and main are
# exercised with a configurable `gh` stub on PATH, so no real API call is made.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/vcluster-release.sh"
  source "$SCRIPT"

  STUB_DIR="$(mktemp -d)"
  PATH="${STUB_DIR}:${PATH}"
  install_gh_stub

  # The pro bump merge-wait polls a stubbed PR; drive it with no real sleeps.
  export BUMP_WAIT_SLEEP_SECONDS=0
}

teardown() {
  rm -rf "$STUB_DIR"
}

# A single configurable `gh` stub. It reads which branches/releases/tags "exist"
# from env set per-test:
#   GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
#   GH_STUB_RELEASES="loft-sh/vcluster:v0.35.4"
#   GH_STUB_TAGS="loft-sh/vcluster-pro:v0.35.4"
# Anything not listed 404s / is absent. POST refs, refs/heads sha lookups and
# `workflow run` succeed (only reached in non-dry-run tests). GH_STUB_TRANSIENT /
# GH_STUB_UNEXPECTED simulate API failures on every probe; GH_STUB_TRANSIENT_TAGS
# scopes a transient failure to the double-cut probes only (branch check still
# passes), to exercise guard_not_released's transient handling in isolation.
install_gh_stub() {
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
set -u
sub="$1"; shift || true

contains() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

if [[ "$sub" == "api" ]]; then
  path="$1"
  # emit_status <present:0|1> <scope> - print an HTTP status line and exit like
  # real gh. Real gh prints the status line to stdout for 200 AND 404, but exits
  # non-zero on 404. GH_STUB_TRANSIENT=1 simulates a network/auth failure (no
  # status line, non-zero exit) on every probe. GH_STUB_TRANSIENT_TAGS=1 scopes
  # that same failure to the double-cut probes only (scope=tags), so a test can
  # let the branch check pass and still exercise the guard's transient handling.
  # GH_STUB_UNEXPECTED=1 simulates an unexpected status (403/500) that is neither
  # 200 nor 404 - it must abort, not fall back.
  emit_status() {
    if [[ "${GH_STUB_TRANSIENT:-}" == "1" ]]; then exit 1; fi
    if [[ "$2" == "tags" && "${GH_STUB_TRANSIENT_TAGS:-}" == "1" ]]; then exit 1; fi
    if [[ "${GH_STUB_UNEXPECTED:-}" == "1" ]]; then echo "HTTP/2.0 403 Forbidden"; exit 1; fi
    if [[ "$1" == "0" ]]; then echo "HTTP/2.0 200 OK"; exit 0; else echo "HTTP/2.0 404 Not Found"; exit 1; fi
  }
  case "$path" in
    repos/*/branches/*)
      rest="${path#repos/}"; repo="${rest%%/branches/*}"; branch="${rest##*/branches/}"
      contains "${GH_STUB_BRANCHES:-}" "${repo}:${branch}" && emit_status 0 branches || emit_status 1 branches ;;
    repos/*/releases/tags/*)
      rest="${path#repos/}"; repo="${rest%%/releases/tags/*}"; tag="${rest##*/releases/tags/}"
      contains "${GH_STUB_RELEASES:-}" "${repo}:${tag}" && emit_status 0 tags || emit_status 1 tags ;;
    repos/*/git/ref/tags/*)
      # Singular endpoint: exact match, 404 otherwise (mirrors the real API).
      rest="${path#repos/}"; repo="${rest%%/git/ref/tags/*}"; tag="${rest##*/git/ref/tags/}"
      contains "${GH_STUB_TAGS:-}" "${repo}:${tag}" && emit_status 0 tags || emit_status 1 tags ;;
    repos/*/git/refs/tags/*)
      # Plural endpoint: prefix match (mirrors the real API). Kept so a regression
      # from the singular exact-match endpoint trips the false-double-cut test.
      rest="${path#repos/}"; repo="${rest%%/git/refs/tags/*}"; tag="${rest##*/git/refs/tags/}"
      for entry in ${GH_STUB_TAGS:-}; do
        [[ "${entry%%:*}" == "$repo" && "${entry#*:}" == "${tag}"* ]] && emit_status 0 tags
      done
      emit_status 1 tags ;;
    repos/*/git/refs/heads/*)
      echo "deadbeefcafe"; exit 0 ;;
    repos/*/pulls*)
      # Emulate `gh api <pulls> --jq '.[0] | "\(.state)|\(.merged_at)"'`. The stub
      # replaces gh (no real jq), so echo the exact tuple wait_for_bump_merge
      # parses. GH_STUB_BUMP_PR selects the PR state; default merged so the happy
      # path needs no extra setup. A merged PR is state=closed with merged_at set.
      case "${GH_STUB_BUMP_PR:-merged}" in
        merged) echo "closed|2026-01-02T03:04:05Z" ;;
        closed) echo "closed|" ;;
        open)   echo "open|" ;;
        *)      echo "none|" ;;
      esac
      exit 0 ;;
    *)
      # POST repos/<repo>/git/refs and anything else: succeed.
      exit 0 ;;
  esac
fi

if [[ "$sub" == "workflow" && "${1:-}" == "run" ]]; then exit 0; fi

exit 0
EOF
  chmod +x "${STUB_DIR}/gh"
}

# ---- normalize_version (pure) ----

@test "normalize_version: bare version gains the leading v" {
  run normalize_version "0.37.1"
  [ "$status" -eq 0 ]
  [ "$output" = "v0.37.1" ]
}

@test "normalize_version: already-canonical version is untouched" {
  run normalize_version "v0.37.1"
  [ "$output" = "v0.37.1" ]
}

@test "normalize_version: prerelease suffixes survive normalization" {
  run normalize_version "0.37.0-rc.1"
  [ "$output" = "v0.37.0-rc.1" ]
  run normalize_version "0.37.0-next.internal.3"
  [ "$output" = "v0.37.0-next.internal.3" ]
}

@test "normalize_version: capitalized V is accepted" {
  run normalize_version "V0.37.1"
  [ "$output" = "v0.37.1" ]
}

@test "normalize_version: surrounding whitespace from a paste is stripped" {
  run normalize_version "  v0.37.1  "
  [ "$output" = "v0.37.1" ]
  run normalize_version "	0.37.1 "
  [ "$output" = "v0.37.1" ]
}

@test "normalize_version: does not eat a v inside the version" {
  # only a LEADING v is structural; nothing else may be rewritten
  run normalize_version "0.37.0-preview.1"
  [ "$output" = "v0.37.0-preview.1" ]
}

# ---- validate_version (pure) ----

@test "validate_version: accepts every shape we actually cut" {
  for v in v0.37.1 v1.2.3 v0.37.0-rc.1 v0.37.0-alpha.1 v0.37.0-beta.1 \
           v0.37.0-next.1 v0.37.0-next.internal.3 v0.36.10-rc.11 ; do
    run validate_version "$v"
    [ "$status" -eq 0 ] || { echo "rejected a legitimate version: $v"; false; }
  done
}

@test "validate_version: rejects a truncated vX.Y (would collide with the release branch)" {
  run validate_version "v0.37"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
}

@test "validate_version: rejects a four-part version" {
  run validate_version "v0.37.1.2"
  [ "$status" -ne 0 ]
}

@test "validate_version: rejects a bare version (normalize_version runs first)" {
  run validate_version "0.37.1"
  [ "$status" -ne 0 ]
}

@test "validate_version: rejects build metadata, which no consumer handles" {
  run validate_version "v0.37.1+build.5"
  [ "$status" -ne 0 ]
}

@test "validate_version: rejects garbage and non-numeric components" {
  for v in abc v0.37.x vx.y.z "" v0.37.1- ; do
    run validate_version "$v"
    [ "$status" -ne 0 ] || { echo "accepted garbage: '$v'"; false; }
  done
}

# ---- main: validation gates before anything is read or mutated ----

@test "main: a truncated version is rejected before any branch read or tag" {
  INPUT_VERSION="v0.37" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
  [[ "$output" != *"refs/tags/"* ]]
  [[ "$output" != *"Routing"* ]]
}

@test "main: a four-part version is rejected" {
  INPUT_VERSION="v0.37.1.2" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" != *"refs/tags/"* ]]
}

@test "main: validation runs on the NORMALIZED value, not the raw input" {
  # "V0.37.1" is invalid as typed; normalization repairs it, so it must be
  # accepted - the gate must not fire on the raw string.
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.37"
  INPUT_VERSION="V0.37.1" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"normalized version 'V0.37.1' -> 'v0.37.1'"* ]]
  [[ "$output" == *"ref=refs/tags/v0.37.1"* ]]
}

@test "main: a bare truncated version still fails after normalization" {
  INPUT_VERSION="0.37" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
}

@test "main: a legacy-line version is validated too (one gate for every era)" {
  INPUT_VERSION="v0.36" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid release version"* ]]
}

# ---- main: a bare version routes and tags identically to the v-prefixed one ----

@test "main: bare version is normalized before tagging and dispatch" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.37"
  INPUT_VERSION="0.37.1" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"normalized version '0.37.1' -> 'v0.37.1'"* ]]
  [[ "$output" == *"ref=refs/tags/v0.37.1"* ]]
  [[ "$output" != *"refs/tags/0.37.1 "* ]]
  [[ "$output" == *"gh workflow run release.yaml --repo loft-sh/vcluster-pro --ref v0.37.1"* ]]
}

@test "main: a bare version does NOT bypass the double-cut guard" {
  # The regression this normalization exists to prevent: probing for "0.37.1"
  # 404s while "v0.37.1" is already shipped, silently re-releasing it.
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.37"
  export GH_STUB_RELEASES="loft-sh/vcluster-pro:v0.37.1"
  INPUT_VERSION="0.37.1" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release v0.37.1 already exists"* ]]
}

@test "main: bare legacy version tags both repos with the v-prefixed tag" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.36 loft-sh/vcluster-pro:v0.36"
  INPUT_VERSION="0.36.5" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ref=refs/tags/v0.36.5 -f sha=<v0.36 head>"* ]]
  [[ "$output" == *"--repo loft-sh/vcluster --ref v0.36.5"* ]]
  [[ "$output" == *"--repo loft-sh/vcluster-pro --ref v0.36.5"* ]]
}

@test "main: a canonical version logs no normalization notice" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.37"
  INPUT_VERSION="v0.37.1" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"normalized version"* ]]
}

# ---- parse_major_minor (pure) ----

@test "parse_major_minor: v-prefixed patch+prerelease -> major minor" {
  run parse_major_minor "v0.35.4-rc.1"
  [ "$status" -eq 0 ]
  [ "$output" = "0 35" ]
}

@test "parse_major_minor: bare major.minor" {
  run parse_major_minor "1.0"
  [ "$output" = "1 0" ]
}

@test "parse_major_minor: prerelease directly on minor -> strips suffix" {
  run parse_major_minor "v0.36-rc.1"
  [ "$output" = "0 36" ]
}

@test "parse_major_minor: double-digit minor" {
  run parse_major_minor "v0.123.4"
  [ "$output" = "0 123" ]
}

@test "parse_major_minor: garbage fails loudly" {
  run parse_major_minor "not-a-version"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot parse major.minor"* ]]
}

# ---- derive_line (pure) ----

@test "derive_line: v0.35.4-rc.1 -> v0.35" {
  run derive_line "v0.35.4-rc.1"
  [ "$output" = "v0.35" ]
}

@test "derive_line: v0.36.0-rc.1 -> v0.36" {
  run derive_line "v0.36.0-rc.1"
  [ "$output" = "v0.36" ]
}

@test "derive_line: v1.2.3 -> v1.2" {
  run derive_line "v1.2.3"
  [ "$output" = "v1.2" ]
}

# ---- classify_era (pure) ----

@test "classify_era: v0.9 is legacy (numeric, not string, compare)" {
  run classify_era "v0.9.0"
  [ "$output" = "legacy" ]
}

@test "classify_era: v0.31 is legacy" {
  run classify_era "v0.31.7"
  [ "$output" = "legacy" ]
}

@test "classify_era: v0.35.4 is legacy" {
  run classify_era "v0.35.4"
  [ "$output" = "legacy" ]
}

@test "classify_era: v0.35.9-rc.1 is legacy" {
  run classify_era "v0.35.9-rc.1"
  [ "$output" = "legacy" ]
}

@test "classify_era: v0.36 is legacy (last legacy line, below the v0.37 cutover)" {
  run classify_era "v0.36.0"
  [ "$output" = "legacy" ]
}

@test "classify_era: v0.36.0-rc.1 is legacy" {
  run classify_era "v0.36.0-rc.1"
  [ "$output" = "legacy" ]
}

@test "classify_era: v0.37 (cutover boundary) is monorepo" {
  run classify_era "v0.37.0"
  [ "$output" = "monorepo" ]
}

@test "classify_era: v0.37.0-rc.1 is monorepo" {
  run classify_era "v0.37.0-rc.1"
  [ "$output" = "monorepo" ]
}

@test "classify_era: v1.0.0 lands in monorepo era" {
  run classify_era "v1.0.0"
  [ "$output" = "monorepo" ]
}

@test "classify_era: honours a custom cutover" {
  run classify_era "v0.34.0" "v0.34"
  [ "$output" = "monorepo" ]
}

# ---- main: legacy flow (dry-run) ----

@test "legacy dry-run: dispatches OSS before pro, tags both, fires nothing" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> legacy"* ]]
  # OSS dispatch line appears before the pro dispatch line.
  oss_line=$(printf '%s\n' "$output" | grep -n 'gh workflow run release.yaml --repo loft-sh/vcluster ' | head -1 | cut -d: -f1)
  pro_line=$(printf '%s\n' "$output" | grep -n 'gh workflow run release.yaml --repo loft-sh/vcluster-pro ' | head -1 | cut -d: -f1)
  [ -n "$oss_line" ] && [ -n "$pro_line" ] && [ "$oss_line" -lt "$pro_line" ]
  # Both repos are tagged, and the tag-before-dispatch invariant holds: each
  # tag POST must precede the first dispatch line.
  oss_tag=$(printf '%s\n' "$output" | grep -n 'POST repos/loft-sh/vcluster/git/refs ' | head -1 | cut -d: -f1)
  pro_tag=$(printf '%s\n' "$output" | grep -n 'POST repos/loft-sh/vcluster-pro/git/refs ' | head -1 | cut -d: -f1)
  [ -n "$oss_tag" ] && [ -n "$pro_tag" ]
  [ "$oss_tag" -lt "$oss_line" ]
  [ "$pro_tag" -lt "$oss_line" ]
  # Dry-run only: never actually dispatched.
  [[ "$output" != *"dispatched release.yaml"* ]]
}

@test "legacy dry-run: prints the pro bump dispatch + merge-wait between the two tags, mutates nothing" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] gh workflow run release-bump-vcluster.yaml --repo loft-sh/vcluster-pro --ref main -f version=v0.35.4 -f branch=v0.35"* ]]
  [[ "$output" == *"would wait for PR loft-sh:chore/v0.35/bump-vcluster-v0.35.4 -> v0.35 to merge"* ]]
  # Order: OSS tag POST -> bump dispatch -> pro tag POST (go get needs the OSS
  # tag first; pro is tagged only after the bump).
  oss_tag=$(printf '%s\n' "$output" | grep -n 'repos/loft-sh/vcluster/git/refs' | head -1 | cut -d: -f1)
  bump=$(printf '%s\n' "$output" | grep -n 'gh workflow run release-bump-vcluster.yaml' | head -1 | cut -d: -f1)
  pro_tag=$(printf '%s\n' "$output" | grep -n 'repos/loft-sh/vcluster-pro/git/refs' | head -1 | cut -d: -f1)
  [ -n "$oss_tag" ] && [ -n "$bump" ] && [ -n "$pro_tag" ]
  [ "$oss_tag" -lt "$bump" ]
  [ "$bump" -lt "$pro_tag" ]
}

@test "legacy: missing branch in a repo is a hard error" {
  # OSS has the branch, pro does not.
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found in loft-sh/vcluster-pro"* ]]
}

@test "legacy: existing release is a double-cut hard error" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  export GH_STUB_RELEASES="loft-sh/vcluster:v0.35.4"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "legacy: existing tag is a double-cut hard error" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  export GH_STUB_TAGS="loft-sh/vcluster:v0.35.4"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag v0.35.4 already exists"* ]]
}

@test "guard: a transient failure on the double-cut probe aborts loudly (not read as not-released)" {
  # The branch check passes; only the guard's release/tag probe transient-fails.
  # guard_not_released must abort, not silently treat the API error as "absent".
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.37"
  export GH_STUB_TRANSIENT_TAGS="1"
  INPUT_VERSION="v0.37.2" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to reach"* ]]
}

@test "legacy: a prerelease tag does not trip the final release's double-cut guard" {
  # v0.35.4-rc.1 is tagged; cutting the final v0.35.4 must NOT be seen as an
  # existing tag. The singular git/ref/tags/ endpoint exact-matches; a regression
  # to the plural prefix-matching endpoint would falsely trip the guard here.
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  export GH_STUB_TAGS="loft-sh/vcluster:v0.35.4-rc.1 loft-sh/vcluster-pro:v0.35.4-rc.1"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"already exists"* ]]
}

# ---- main: monorepo flow (dry-run) ----

@test "monorepo dry-run: pro-only dispatch, target line branch when it exists" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.37"
  INPUT_VERSION="v0.37.2" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> monorepo"* ]]
  [[ "$output" == *"target v0.37"* ]]
  [[ "$output" == *"gh workflow run release.yaml --repo loft-sh/vcluster-pro --ref v0.37.2"* ]]
  # No OSS dispatch on the monorepo path.
  [[ "$output" != *"--repo loft-sh/vcluster "* ]]
}

@test "monorepo: stable with no vX.Y branch is a hard error (no fallback to main)" {
  # Matrix rule: stable is cut from the vX.Y release branch only. A missing v0.37
  # branch (real 404, gh exits non-zero) must fail loudly, never silently retarget
  # main. branch_exists still distinguishes 404 from a transient failure.
  export GH_STUB_BRANCHES=""
  INPUT_VERSION="v0.37.0" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"release branch 'v0.37' not found"* ]]
  [[ "$output" != *"failed to reach"* ]]
}

@test "monorepo rc: an omitted source-branch defaults to main" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:main"
  INPUT_VERSION="v0.40.0-rc.1" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"target main"* ]]
  [[ "$output" == *"[dry-run] gh workflow run release.yaml --repo loft-sh/vcluster-pro --ref v0.40.0-rc.1"* ]]
}

@test "monorepo rc: an explicit vX.Y source-branch targets the release branch" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.40"
  INPUT_VERSION="v0.40.0-rc.1" INPUT_SOURCE_BRANCH="v0.40" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"target v0.40"* ]]
}

@test "monorepo rc: a foreign source-branch is rejected" {
  INPUT_VERSION="v0.40.0-rc.1" INPUT_SOURCE_BRANCH="my-feature" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"rc releases are cut from main or the v0.40 release branch"* ]]
}

@test "monorepo alpha: defaults to main; a non-main source-branch is rejected" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:main"
  INPUT_VERSION="v0.40.0-alpha.1" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"target main"* ]]

  INPUT_VERSION="v0.40.0-alpha.1" INPUT_SOURCE_BRANCH="v0.40" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"alpha releases are cut from main only"* ]]
}

@test "monorepo: a genuine transient API failure aborts loudly (not read as missing)" {
  export GH_STUB_TRANSIENT="1"
  INPUT_VERSION="v0.37.0" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to reach"* ]]
}

@test "monorepo: existing release is a double-cut hard error" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.37"
  export GH_STUB_RELEASES="loft-sh/vcluster-pro:v0.37.2"
  INPUT_VERSION="v0.37.2" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

# ---- main: guards ----

@test "main requires INPUT_VERSION" {
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"INPUT_VERSION is required"* ]]
}

# ---- main: live (non-dry-run) path ----

@test "legacy non-dry-run: reaches the mutating path (real tag + dispatch), emits recovery notice" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  # The mutating branches ran, not the dry-run prints.
  [[ "$output" == *"created tag v0.35.4 in loft-sh/vcluster "* ]]
  [[ "$output" == *"created tag v0.35.4 in loft-sh/vcluster-pro "* ]]
  [[ "$output" == *"dispatched release.yaml in loft-sh/vcluster "* ]]
  [[ "$output" == *"dispatched release.yaml in loft-sh/vcluster-pro "* ]]
  [[ "$output" != *"[dry-run]"* ]]
  # Partial-failure recovery hint fires only on the live path.
  [[ "$output" == *"do NOT delete tags and re-run this action"* ]]
}

@test "legacy non-dry-run: bumps pro (merged) then tags pro after the merge" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  export GH_STUB_BUMP_PR="merged"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatching release-bump-vcluster.yaml to bump loft-sh/vcluster-pro@v0.35 to v0.35.4"* ]]
  [[ "$output" == *"bump PR chore/v0.35/bump-vcluster-v0.35.4 merged into v0.35"* ]]
  [[ "$output" != *"[dry-run]"* ]]
  # OSS tag before the merge; pro tag only after it.
  oss_tag=$(printf '%s\n' "$output" | grep -n 'created tag v0.35.4 in loft-sh/vcluster ' | head -1 | cut -d: -f1)
  merged=$(printf '%s\n' "$output" | grep -n 'merged into v0.35' | head -1 | cut -d: -f1)
  pro_tag=$(printf '%s\n' "$output" | grep -n 'created tag v0.35.4 in loft-sh/vcluster-pro ' | head -1 | cut -d: -f1)
  [ "$oss_tag" -lt "$merged" ]
  [ "$merged" -lt "$pro_tag" ]
}

@test "legacy non-dry-run: a bump PR closed without merging aborts before tagging pro" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  export GH_STUB_BUMP_PR="closed"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"closed without merging"* ]]
  # Pro is never tagged and OSS is never dispatched against an un-bumped go.mod.
  [[ "$output" != *"created tag v0.35.4 in loft-sh/vcluster-pro "* ]]
  [[ "$output" != *"dispatched release.yaml in loft-sh/vcluster "* ]]
}

@test "legacy non-dry-run: a bump PR that never merges times out and aborts" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  export GH_STUB_BUMP_PR="open"
  export BUMP_WAIT_ATTEMPTS=3
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="false" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]]
  [[ "$output" != *"created tag v0.35.4 in loft-sh/vcluster-pro "* ]]
}

@test "monorepo non-dry-run: reaches the mutating pro-only path" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.37"
  INPUT_VERSION="v0.37.2" INPUT_DRY_RUN="false" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"created tag v0.37.2 in loft-sh/vcluster-pro "* ]]
  [[ "$output" == *"dispatched release.yaml in loft-sh/vcluster-pro "* ]]
  [[ "$output" != *"[dry-run]"* ]]
  # No OSS mutation on the monorepo path.
  [[ "$output" != *"in loft-sh/vcluster "* ]]
}

@test "dry-run fail-closed: an unrecognized value stays dry (no mutation), warns" {
  # 'yes' is neither 'true' nor 'false' - must NOT be read as "cut for real".
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="yes" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecognized dry-run value"* ]]
  [[ "$output" == *"dry_run=true"* ]]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" != *"dispatched release.yaml"* ]]
}

@test "dry-run fail-closed: only an explicit false cuts for real (case-insensitive)" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="False" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry_run=false"* ]]
  [[ "$output" == *"dispatched release.yaml"* ]]
  [[ "$output" != *"[dry-run]"* ]]
}

@test "monorepo: an unexpected HTTP status (403/500) aborts loudly (not read as missing)" {
  # The *) arm of branch_exists: neither 200 nor 404 must hard-fail, never fall
  # back to main.
  export GH_STUB_UNEXPECTED="1"
  INPUT_VERSION="v0.37.0" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected status"* ]]
}

# ---- classify_suffix (pure) ----

@test "classify_suffix: stable / alpha / beta / rc" {
  run classify_suffix "v0.40.0";        [ "$output" = "stable" ]
  run classify_suffix "v0.40.0-alpha.1"; [ "$output" = "alpha" ]
  run classify_suffix "v0.40.0-beta.2";  [ "$output" = "beta" ]
  run classify_suffix "v0.40.0-rc.3";    [ "$output" = "rc" ]
}

@test "classify_suffix: -next.internal is matched before -next" {
  run classify_suffix "v0.40.0-next.internal.1"
  [ "$output" = "next-internal" ]
  run classify_suffix "v0.40.0-next.5"
  [ "$output" = "next" ]
}

@test "classify_suffix: an unrouted legal suffix (-devpod.alpha) is fail-closed" {
  run classify_suffix "v0.40.0-devpod.alpha.1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported prerelease suffix"* ]]
}

# ---- is_feature_branch (pure) ----

@test "is_feature_branch: main and vX.Y are not feature branches; anything else is" {
  run is_feature_branch "my-feature"; [ "$status" -eq 0 ]
  run is_feature_branch "dmytrosydorov/foo"; [ "$status" -eq 0 ]
  run is_feature_branch "main"; [ "$status" -ne 0 ]
  run is_feature_branch "v0.40"; [ "$status" -ne 0 ]
}

# ---- resolve_target (pure) ----

@test "resolve_target: stable requires the line branch; a foreign source is rejected" {
  run resolve_target "stable" "" "v0.40";        [ "$output" = "v0.40" ]
  run resolve_target "stable" "v0.40" "v0.40";   [ "$output" = "v0.40" ]
  run resolve_target "stable" "main" "v0.40";    [ "$status" -ne 0 ]
}

@test "resolve_target: rc defaults to main, accepts main or the line branch, rejects a foreign source" {
  run resolve_target "rc" "" "v0.40";          [ "$output" = "main" ]
  run resolve_target "rc" "main" "v0.40";      [ "$output" = "main" ]
  run resolve_target "rc" "v0.40" "v0.40";     [ "$output" = "v0.40" ]
  run resolve_target "rc" "my-feature" "v0.40"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rc releases are cut from main or the v0.40 release branch"* ]]
}

@test "resolve_target: alpha/beta default to main, accept main, reject anything else" {
  run resolve_target "alpha" "" "v0.40";     [ "$output" = "main" ]
  run resolve_target "alpha" "main" "v0.40"; [ "$output" = "main" ]
  run resolve_target "beta" "" "v0.40";      [ "$output" = "main" ]
  run resolve_target "alpha" "v0.40" "v0.40"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alpha releases are cut from main only"* ]]
  run resolve_target "beta" "v0.40" "v0.40"
  [ "$status" -ne 0 ]
  [[ "$output" == *"beta releases are cut from main only"* ]]
}

# ---- main: feature-branch prereleases (-next / -next.internal) ----

@test "next: cut from a feature branch, pro-only, tags the feature head" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:my-feature"
  INPUT_VERSION="v0.40.0-next.1" INPUT_SOURCE_BRANCH="my-feature" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature-branch prerelease (source my-feature)"* ]]
  [[ "$output" == *"[dry-run] gh workflow run release.yaml --repo loft-sh/vcluster-pro --ref v0.40.0-next.1"* ]]
  # feature head is tagged, and OSS is never touched.
  [[ "$output" == *"repos/loft-sh/vcluster-pro/git/refs -f ref=refs/tags/v0.40.0-next.1 -f sha=<my-feature head>"* ]]
  [[ "$output" != *"loft-sh/vcluster/"* ]]
}

@test "next.internal: also cut from a feature branch, pro-only" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:my-feature"
  INPUT_VERSION="v0.40.0-next.internal.2" INPUT_SOURCE_BRANCH="my-feature" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature-branch prerelease (source my-feature)"* ]]
}

@test "TRIGGERED_BY: forwarded as -f triggered_by on the feature-prerelease dispatch" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:my-feature"
  TRIGGERED_BY="alice" INPUT_VERSION="v0.40.0-next.1" INPUT_SOURCE_BRANCH="my-feature" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh workflow run release.yaml --repo loft-sh/vcluster-pro --ref v0.40.0-next.1 -f triggered_by=alice"* ]]
}

@test "TRIGGERED_BY: forwarded on the monorepo dispatch too" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.40"
  TRIGGERED_BY="bob" INPUT_VERSION="v0.40.1" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"--repo loft-sh/vcluster-pro --ref v0.40.1 -f triggered_by=bob"* ]]
}

@test "TRIGGERED_BY: never passed on legacy dispatches (release.yaml lacks the input)" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  TRIGGERED_BY="carol" INPUT_VERSION="v0.35.4" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" != *"triggered_by"* ]]
}

@test "next: a missing source-branch is a hard error" {
  INPUT_VERSION="v0.40.0-next.1" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"require the source-branch input"* ]]
}

@test "next.internal: a missing source-branch is a hard error" {
  INPUT_VERSION="v0.40.0-next.internal.1" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"require the source-branch input"* ]]
}

@test "next: main and vX.Y sources are rejected (feature branch only)" {
  INPUT_VERSION="v0.40.0-next.1" INPUT_SOURCE_BRANCH="main" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"short-lived feature branch"* ]]

  INPUT_VERSION="v0.40.0-next.1" INPUT_SOURCE_BRANCH="v0.40" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"short-lived feature branch"* ]]
}

# ---- main: legacy line only accepts rc/stable ----

@test "legacy: alpha/beta/next are rejected on a legacy line" {
  INPUT_VERSION="v0.35.0-alpha.1" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not supported on the legacy line v0.35"* ]]
}

@test "legacy: a foreign source-branch is rejected (must be the line branch)" {
  INPUT_VERSION="v0.35.4" INPUT_SOURCE_BRANCH="my-feature" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"legacy v0.35 releases are cut from the v0.35 branch, not 'my-feature'"* ]]
}

@test "legacy: an explicit source-branch equal to the line branch is accepted" {
  export GH_STUB_BRANCHES="loft-sh/vcluster:v0.35 loft-sh/vcluster-pro:v0.35"
  INPUT_VERSION="v0.35.4" INPUT_SOURCE_BRANCH="v0.35" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> legacy (line v0.35)"* ]]
  [[ "$output" == *"gh workflow run release.yaml --repo loft-sh/vcluster --ref v0.35.4"* ]]
}

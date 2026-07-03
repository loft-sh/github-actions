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
# `workflow run` succeed (only reached in non-dry-run tests).
install_gh_stub() {
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
set -u
sub="$1"; shift || true

contains() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

if [[ "$sub" == "api" ]]; then
  path="$1"
  case "$path" in
    repos/*/branches/*)
      rest="${path#repos/}"; repo="${rest%%/branches/*}"; branch="${rest##*/branches/}"
      # Real gh: prints the status line to stdout for both, but exits non-zero on
      # 404. GH_STUB_TRANSIENT=1 simulates a network/auth failure (no status line,
      # non-zero exit).
      if [[ "${GH_STUB_TRANSIENT:-}" == "1" ]]; then exit 1; fi
      if contains "${GH_STUB_BRANCHES:-}" "${repo}:${branch}"; then echo "HTTP/2.0 200 OK"; exit 0; else echo "HTTP/2.0 404 Not Found"; exit 1; fi ;;
    repos/*/git/refs/tags/*)
      rest="${path#repos/}"; repo="${rest%%/git/refs/tags/*}"; tag="${rest##*/git/refs/tags/}"
      contains "${GH_STUB_TAGS:-}" "${repo}:${tag}" && exit 0 || exit 1 ;;
    repos/*/git/refs/heads/*)
      echo "deadbeefcafe"; exit 0 ;;
    *)
      # POST repos/<repo>/git/refs and anything else: succeed.
      exit 0 ;;
  esac
fi

if [[ "$sub" == "release" && "${1:-}" == "view" ]]; then
  tag="$2"; repo=""
  while [[ $# -gt 0 ]]; do [[ "$1" == "--repo" ]] && repo="$2"; shift; done
  contains "${GH_STUB_RELEASES:-}" "${repo}:${tag}" && exit 0 || exit 1
fi

if [[ "$sub" == "workflow" && "${1:-}" == "run" ]]; then exit 0; fi

exit 0
EOF
  chmod +x "${STUB_DIR}/gh"
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

@test "classify_era: v0.36 (cutover boundary) is monorepo" {
  run classify_era "v0.36.0"
  [ "$output" = "monorepo" ]
}

@test "classify_era: v0.36.0-rc.1 is monorepo" {
  run classify_era "v0.36.0-rc.1"
  [ "$output" = "monorepo" ]
}

@test "classify_era: v0.37 is monorepo" {
  run classify_era "v0.37.2"
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
  # Dry-run only: never actually dispatched.
  [[ "$output" != *"dispatched release.yaml"* ]]
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

# ---- main: monorepo flow (dry-run) ----

@test "monorepo dry-run: pro-only dispatch, target line branch when it exists" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.36"
  INPUT_VERSION="v0.36.2" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> monorepo"* ]]
  [[ "$output" == *"target v0.36"* ]]
  [[ "$output" == *"gh workflow run release.yaml --repo loft-sh/vcluster-pro --ref v0.36.2"* ]]
  # No OSS dispatch on the monorepo path.
  [[ "$output" != *"--repo loft-sh/vcluster "* ]]
}

@test "monorepo dry-run: falls back to main when the line branch is absent (404 exits non-zero)" {
  # Regression: a real 404 makes gh exit non-zero. branch_exists must read that
  # as "missing" (-> main), not as a transient error that aborts the cut.
  export GH_STUB_BRANCHES=""
  INPUT_VERSION="v0.36.0" INPUT_DRY_RUN="true" run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"target main"* ]]
  [[ "$output" != *"failed to reach"* ]]
}

@test "monorepo: a genuine transient API failure aborts loudly (not read as missing)" {
  export GH_STUB_TRANSIENT="1"
  INPUT_VERSION="v0.36.0" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to reach"* ]]
}

@test "monorepo: existing release is a double-cut hard error" {
  export GH_STUB_BRANCHES="loft-sh/vcluster-pro:v0.36"
  export GH_STUB_RELEASES="loft-sh/vcluster-pro:v0.36.2"
  INPUT_VERSION="v0.36.2" INPUT_DRY_RUN="true" run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

# ---- main: guards ----

@test "main requires INPUT_VERSION" {
  run main
  [ "$status" -ne 0 ]
  [[ "$output" == *"INPUT_VERSION is required"* ]]
}

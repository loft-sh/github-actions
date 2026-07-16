#!/usr/bin/env bats
# Tests for run.sh
#
# The lifecycle doc is served from a local file:// URL so the tests are
# hermetic (no network) and TODAY is pinned for deterministic EOL math. A
# bogus URL exercises the fallback path. LABELS is a JSON array, matching what
# toJSON(github.event.pull_request.labels.*.name) yields in the workflow.

# jq-encode the argument list into a JSON array of label names.
labels_json() { printf '%s\n' "$@" | jq -R . | jq -cs .; }

setup() {
  ROOT=$(mktemp -d)
  export ROOT
  SCRIPT="$BATS_TEST_DIRNAME/../run.sh"
  export GITHUB_OUTPUT="$ROOT/output"
  : > "$GITHUB_OUTPUT"

  # Descending support ladder mirroring the real doc: v0.31+ in-support,
  # v0.30 and below EOL. v0.36 is intentionally ABSENT (freshly cut line).
  export LIFECYCLE_URL="file://$ROOT/lifecycle.json"
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.35.0","status":"active","eolDate":"2026-12-16"},
  {"version":"0.34.0","status":"active","eolDate":"2026-10-29"},
  {"version":"0.33.0","status":"eos","eolDate":"2026-09-13"},
  {"version":"0.32.0","status":"eos","eolDate":"2026-08-18"},
  {"version":"0.31.0","status":"eos","eolDate":"2026-07-29"},
  {"version":"0.30.0","status":"eol","eolDate":"2026-04-28"},
  {"version":"0.24.0","status":"eol","eolDate":"2025-09-14"}
]}
JSON

  export TODAY="2026-07-15"
  export MAX_MINOR=36
}

teardown() { rm -rf "$ROOT"; }

out() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n1 | cut -d= -f2-; }

@test "in-support legacy labels are allowed; ordering follows the labels" {
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.31)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35","v0.31"]' ]
  [ "$(out has-targets)" = "true" ]
}

@test "end-of-life line (v0.30) is dropped" {
  LABELS="$(labels_json backport-to-v0.30)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = "[]" ]
  [ "$(out has-targets)" = "false" ]
  [[ "$output" == *"end-of-life"* ]]
}

@test "monorepo-era line (v0.37) is dropped as too new" {
  LABELS="$(labels_json backport-to-v0.37)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = "[]" ]
  # A bug that emitted has-targets=true alongside targets=[] in the >MAX_MINOR
  # path would slip past a targets-only assertion; pin both outputs.
  [ "$(out has-targets)" = "false" ]
  [[ "$output" == *"monorepo era"* ]]
}

@test "freshly cut v0.36, absent from the doc, is allowed (<= max, >= min)" {
  LABELS="$(labels_json backport-to-v0.36)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.36"]' ]
}

@test "non-backport and non-v0.x labels are ignored" {
  LABELS="$(labels_json kind/bug backport-to-v1.0 backport-to-v0.34)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.34"]' ]
}

@test "labels containing spaces are handled (JSON array, not split)" {
  LABELS="$(labels_json 'good first issue' backport-to-v0.34)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.34"]' ]
}

@test "duplicate labels collapse to one target" {
  LABELS="$(labels_json backport-to-v0.34 backport-to-v0.34)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.34"]' ]
}

@test "EOL boundary is exclusive on the eol date itself" {
  # On v0.31's eolDate, it is no longer in support -> min becomes v0.32.
  TODAY="2026-07-29" LABELS="$(labels_json backport-to-v0.31 backport-to-v0.32)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.32"]' ]
}

@test "unreadable lifecycle doc falls back to hardcoded min minor" {
  LIFECYCLE_URL="file://$ROOT/does-not-exist.json" \
    LABELS="$(labels_json backport-to-v0.31 backport-to-v0.30)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # Fallback min is 31: v0.31 allowed, v0.30 dropped.
  [ "$(out targets)" = '["v0.31"]' ]
  [[ "$output" == *"falling back"* ]]
}

@test "non-contiguous lifecycle: an EOL line between supported ones is dropped" {
  # Regression guard: a range-based [min,max] gate would allow v0.33 here
  # (min supported = 32). The per-line check drops it on its own eolDate.
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.35.0","status":"active","eolDate":"2026-12-16"},
  {"version":"0.34.0","status":"active","eolDate":"2026-10-29"},
  {"version":"0.33.0","status":"eol","eolDate":"2026-01-10"},
  {"version":"0.32.0","status":"active","eolDate":"2026-11-01"}
]}
JSON
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.33 backport-to-v0.32)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35","v0.32"]' ]
  [[ "$output" == *"end-of-life"* ]]
}

@test "line missing from the doc and below the newest listed line is dropped" {
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.35.0","status":"active","eolDate":"2026-12-16"},
  {"version":"0.34.0","status":"active","eolDate":"2026-10-29"}
]}
JSON
  # v0.32 is unlisted and 32 < 35 -> treated as EOL/unknown, fail closed.
  LABELS="$(labels_json backport-to-v0.34 backport-to-v0.32)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.34"]' ]
}

@test "line with null/missing eolDate is dropped (fail closed)" {
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.35.0","status":"active","eolDate":"2026-12-16"},
  {"version":"0.34.0","status":"active","eolDate":null}
]}
JSON
  # "null" renders as a string that sorts > any date; must NOT be treated as
  # in-support just because status != eol.
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.34)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35"]' ]
}

@test "line with null/missing status is dropped (fail closed)" {
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.35.0","status":"active","eolDate":"2026-12-16"},
  {"version":"0.34.0","status":null,"eolDate":"2026-12-16"}
]}
JSON
  # v0.34 has a future eolDate but a null status -> must NOT be treated as
  # in-support just because status != "eol".
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.34)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35"]' ]
}

@test "a malformed version row is skipped, not fallback-opened (EOL line stays dropped)" {
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.35.0","status":"active","eolDate":"2026-12-16"},
  "junk-scalar-row",
  {"version":0.34,"status":"active","eolDate":"2026-12-16"},
  {"version":"0.x","status":"active","eolDate":"2026-12-16"},
  {"version":"0","status":"active","eolDate":"2026-12-16"},
  [1,2],
  {"version":"0.32.0","status":"eol","eolDate":"2020-01-01"}
]}
JSON
  # None of these bad rows -- non-object (scalar/array), non-string version, or a
  # non-numeric minor ("0.x"/"0", which would break tonumber) -- may abort the
  # parse into the contiguous fallback window (which would re-allow the EOL v0.32).
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.32)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35"]' ]
}

@test "a leading-zero minor label is rejected (no bogus branch target)" {
  # v0.036 must not be normalized to v0.36 (bash -eq reads decimal); reject it.
  LABELS="$(labels_json backport-to-v0.036 backport-to-v0.35)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35"]' ]
  [[ "$output" == *"not a v0.x line"* ]]
}

@test "a non-string status is dropped despite a future eolDate (fail closed)" {
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.35.0","status":"active","eolDate":"2026-12-16"},
  {"version":"0.34.0","status":5,"eolDate":"2027-01-01"}
]}
JSON
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.34)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35"]' ]
}

@test "a fetched top-level non-object doc fails closed (not the fallback window)" {
  printf '[1,2,3]\n' > "$ROOT/lifecycle.json"
  # v0.32 is inside the fallback window [31,36]; a top-level array must NOT open it.
  LABELS="$(labels_json backport-to-v0.32)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = "[]" ]
}

@test "a fetched but non-JSON doc fails closed (not the fallback window)" {
  printf 'totally not json\n' > "$ROOT/lifecycle.json"
  LABELS="$(labels_json backport-to-v0.32)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = "[]" ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "freshly-cut allows only the single next line above the doc's newest" {
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.34.0","status":"active","eolDate":"2026-12-16"},
  {"version":"0.33.0","status":"active","eolDate":"2026-12-16"}
]}
JSON
  # max_listed=34: v0.35 (==max+1) is freshly-cut-allowed; v0.36 (two ahead) is
  # NOT (fail closed).
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.36)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35"]' ]
}

@test "status is matched case-insensitively" {
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"0.35.0","status":"ACTIVE","eolDate":"2026-12-16"},
  {"version":"0.34.0","status":"EOL","eolDate":"2026-12-16"}
]}
JSON
  # "EOL" with a (mislabeled) future eolDate must still be dropped.
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.34)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = '["v0.35"]' ]
}

@test "doc that parses but lists no 0.x lines allows nothing (not the fallback window)" {
  cat > "$ROOT/lifecycle.json" <<'JSON'
{"versions":[
  {"version":"1.1.0","status":"active","eolDate":"2027-12-16"},
  {"version":"1.0.0","status":"active","eolDate":"2027-06-16"}
]}
JSON
  # A parsed doc with no 0.x lines means every legacy line is gone -> allow none.
  # (A range-fallback would wrongly re-allow v0.31-36.)
  LABELS="$(labels_json backport-to-v0.35 backport-to-v0.34)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = "[]" ]
  [ "$(out has-targets)" = "false" ]
}

@test "empty JSON array yields empty targets" {
  LABELS="[]" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = "[]" ]
  [ "$(out has-targets)" = "false" ]
}

@test "blank labels input is treated as no labels" {
  LABELS="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out targets)" = "[]" ]
  [ "$(out has-targets)" = "false" ]
}

@test "malformed (non-JSON) labels input fails loudly" {
  LABELS="not-json" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid JSON array"* ]]
}

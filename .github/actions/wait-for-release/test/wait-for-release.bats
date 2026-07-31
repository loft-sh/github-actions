#!/usr/bin/env bats
# Tests for wait-for-release.sh
#
# Every test runs against a configurable `gh` stub on PATH, so no real API call
# is made and no test needs a token. WAIT_INTERVAL_SECONDS=0 keeps the poll loop
# instant while still exercising the real attempt accounting.
#
# The stub counts only `gh api` calls (release lookups), so GH_STUB_RELEASE_AFTER
# is expressed in polls: "become present on the Nth lookup".

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/wait-for-release.sh"

  STUB_DIR="$(mktemp -d)"
  PATH="${STUB_DIR}:${PATH}"
  export GH_STUB_COUNT_FILE="${STUB_DIR}/count"

  export INPUT_REPO="loft-sh/vcluster"
  export INPUT_VERSION="v0.36.1-rc.2"
  export INPUT_WORKFLOW=""
  export WAIT_MAX_ATTEMPTS=3
  export WAIT_INTERVAL_SECONDS=0
  export WAIT_MAX_API_FAILURES=5
  export GITHUB_OUTPUT="${STUB_DIR}/github_output"

  install_gh_stub
}

teardown() {
  rm -rf "$STUB_DIR"
}

# A single configurable `gh` stub, driven per-test by env:
#   GH_STUB_RELEASE_AFTER=N    release becomes present on the Nth lookup (0 = never)
#   GH_STUB_RELEASE_ERRORS=N   first N lookups fail with a transport error, not a 404
#   GH_STUB_RELEASE_ERROR_EVERY=N  every Nth lookup fails, interleaved with 404s
#   GH_STUB_RUN_STATUS         producer run status   (default in_progress)
#   GH_STUB_RUN_CONCLUSION     producer run conclusion (default empty)
#   GH_STUB_RUN_URL            producer run url
#   GH_STUB_NO_RUN=1           `gh run list` returns [] (dispatch has not landed)
#   GH_STUB_RUN_ERROR=1        `gh run list` fails
install_gh_stub() {
  cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
set -u
sub="$1"; shift || true

if [[ "$sub" == "api" ]]; then
  n=$(( $(cat "${GH_STUB_COUNT_FILE}" 2>/dev/null || echo 0) + 1 ))
  echo "$n" >"${GH_STUB_COUNT_FILE}"

  # A transport/auth failure prints no clean 404 - the script must treat this as
  # "unknown", not "absent".
  if [[ -n "${GH_STUB_RELEASE_ERRORS:-}" ]] && (( n <= GH_STUB_RELEASE_ERRORS )); then
    echo "error connecting to api.github.com" >&2
    exit 1
  fi

  # Partial outage: fail every Nth lookup, so errors interleave with clean 404s
  # and the consecutive counter keeps resetting.
  if [[ -n "${GH_STUB_RELEASE_ERROR_EVERY:-}" ]] && (( n % GH_STUB_RELEASE_ERROR_EVERY == 0 )); then
    echo "HTTP 403: API rate limit exceeded" >&2
    exit 1
  fi

  after="${GH_STUB_RELEASE_AFTER:-0}"
  if (( after > 0 )) && (( n >= after )); then
    echo '{"tag_name":"stub"}'
    exit 0
  fi
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi

if [[ "$sub" == "run" ]]; then
  if [[ "${GH_STUB_RUN_ERROR:-}" == "1" ]]; then
    echo "api error" >&2
    exit 1
  fi
  if [[ "${GH_STUB_NO_RUN:-}" == "1" ]]; then
    echo "[]"
    exit 0
  fi
  # An unconcluded run returns JSON null, not "", and jq -r renders that as the
  # literal string "null". Emit real null so the script's actual parse path is
  # what the suite exercises.
  if [[ -z "${GH_STUB_RUN_CONCLUSION:-}" ]]; then
    conclusion="null"
  else
    conclusion="\"${GH_STUB_RUN_CONCLUSION}\""
  fi
  printf '[{"status":"%s","conclusion":%s,"url":"%s"}]\n' \
    "${GH_STUB_RUN_STATUS:-in_progress}" \
    "$conclusion" \
    "${GH_STUB_RUN_URL:-https://github.com/loft-sh/vcluster/actions/runs/30495974873}"
  exit 0
fi

echo "unexpected gh invocation: ${sub} $*" >&2
exit 1
EOF
  chmod +x "${STUB_DIR}/gh"
}

lookup_count() {
  cat "${GH_STUB_COUNT_FILE}" 2>/dev/null || echo 0
}

# --- presence polling -------------------------------------------------------

@test "succeeds immediately when the release already exists" {
  export GH_STUB_RELEASE_AFTER=1

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"present in loft-sh/vcluster after attempt 1"* ]]
  [ "$(lookup_count)" -eq 1 ]
}

@test "emits waited-seconds and release-url on success" {
  export GH_STUB_RELEASE_AFTER=1

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q '^release-url=https://github.com/loft-sh/vcluster/releases/tag/v0.36.1-rc.2$' "$GITHUB_OUTPUT"
  grep -q '^waited-seconds=' "$GITHUB_OUTPUT"
}

@test "keeps polling until the release appears" {
  export GH_STUB_RELEASE_AFTER=3

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"after attempt 3"* ]]
}

@test "fails with a timeout once attempts are exhausted" {
  export GH_STUB_RELEASE_AFTER=0

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"never appeared in loft-sh/vcluster after 3 attempts"* ]]
  [ "$(lookup_count)" -eq 3 ]
}

# --- fail-fast on a dead producer -------------------------------------------

@test "fails fast when the producer run already failed" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW="release.yaml"
  export GH_STUB_RUN_STATUS="completed"
  export GH_STUB_RUN_CONCLUSION="failure"
  export WAIT_MAX_ATTEMPTS=50

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"already concluded failure"* ]]
  [[ "$output" == *"actions/runs/30495974873"* ]]
  [[ "$output" == *"re-run that workflow first"* ]]
  # The point of failing fast: it must not spend the attempt budget first.
  [ "$(lookup_count)" -eq 1 ]
}

@test "fails fast when the producer run was cancelled" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW="release.yaml"
  export GH_STUB_RUN_STATUS="completed"
  export GH_STUB_RUN_CONCLUSION="cancelled"

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"already concluded cancelled"* ]]
}

@test "fails fast when the producer run timed out" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW="release.yaml"
  export GH_STUB_RUN_STATUS="completed"
  export GH_STUB_RUN_CONCLUSION="timed_out"

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"already concluded timed_out"* ]]
}

@test "fails fast when the producer run hit startup_failure" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW="release.yaml"
  export GH_STUB_RUN_STATUS="completed"
  export GH_STUB_RUN_CONCLUSION="startup_failure"
  export WAIT_MAX_ATTEMPTS=50

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"already concluded startup_failure"* ]]
  [ "$(lookup_count)" -eq 1 ]
}

@test "keeps waiting while the producer run is still in progress" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW="release.yaml"
  export GH_STUB_RUN_STATUS="in_progress"

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"producer run is in_progress"* ]]
  # Timed out rather than failing fast, and used the whole budget.
  [[ "$output" == *"never appeared"* ]]
  [ "$(lookup_count)" -eq 3 ]
}

@test "keeps waiting when the producer run has not been dispatched yet" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW="release.yaml"
  export GH_STUB_NO_RUN=1

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"never appeared"* ]]
  [[ "$output" != *"already concluded"* ]]
  [ "$(lookup_count)" -eq 3 ]
}

@test "keeps waiting when the producer lookup itself errors" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW="release.yaml"
  export GH_STUB_RUN_ERROR=1

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"never appeared"* ]]
  [[ "$output" != *"already concluded"* ]]
}

@test "fails when the producer succeeded but the release stays absent" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW="release.yaml"
  export GH_STUB_RUN_STATUS="completed"
  export GH_STUB_RUN_CONCLUSION="success"
  export WAIT_MAX_ATTEMPTS=50

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"succeeded but release v0.36.1-rc.2 is still absent"* ]]
  # One poll of grace for read lag, then it stops - well short of the budget.
  [ "$(lookup_count)" -eq 2 ]
}

@test "ignores the producer entirely when no workflow is given" {
  export GH_STUB_RELEASE_AFTER=0
  export INPUT_WORKFLOW=""
  # A failed producer is visible, but with no workflow input it must not be read.
  export GH_STUB_RUN_STATUS="completed"
  export GH_STUB_RUN_CONCLUSION="failure"

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" != *"already concluded"* ]]
  [[ "$output" == *"never appeared"* ]]
}

# --- API error handling -----------------------------------------------------

@test "tolerates transient lookup failures and still succeeds" {
  export GH_STUB_RELEASE_ERRORS=2
  export GH_STUB_RELEASE_AFTER=3
  export WAIT_MAX_ATTEMPTS=5

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"release lookup failed (1/5 consecutive)"* ]]
  [[ "$output" == *"after attempt 3"* ]]
}

@test "fails after too many consecutive lookup failures" {
  export GH_STUB_RELEASE_ERRORS=99
  export WAIT_MAX_ATTEMPTS=50
  export WAIT_MAX_API_FAILURES=3

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"giving up after 3 consecutive API failures"* ]]
  [ "$(lookup_count)" -eq 3 ]
}

@test "reports cumulative failures when a partial outage never trips the breaker" {
  # Every 2nd lookup errors, so the consecutive counter resets on the 404s in
  # between and never reaches the ceiling. The wait times out (the safe
  # direction), but the timeout must not read as "the producer was just slow".
  export GH_STUB_RELEASE_AFTER=0
  export GH_STUB_RELEASE_ERROR_EVERY=2
  export WAIT_MAX_ATTEMPTS=6
  export WAIT_MAX_API_FAILURES=3

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" != *"giving up after"* ]]
  [[ "$output" == *"3 of 6 release lookups failed with an API error"* ]]
  [[ "$output" == *"never appeared"* ]]
}

@test "reports no API-failure warning on a clean timeout" {
  export GH_STUB_RELEASE_AFTER=0

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"never appeared"* ]]
  [[ "$output" != *"failed with an API error"* ]]
}

@test "a clean 404 does not count as an API failure" {
  export GH_STUB_RELEASE_AFTER=0
  export WAIT_MAX_API_FAILURES=2

  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  # Absent is not an error: it must reach the timeout, not the API-failure exit.
  [[ "$output" == *"never appeared"* ]]
  [[ "$output" != *"consecutive API failures"* ]]
}

# --- unit-level: the three lookup outcomes stay distinct ---------------------

@test "release_present distinguishes present, absent and error" {
  source "$SCRIPT"

  export GH_STUB_RELEASE_AFTER=1
  run release_present "loft-sh/vcluster" "v0.36.1-rc.2"
  [ "$status" -eq 0 ]

  rm -f "${GH_STUB_COUNT_FILE}"
  export GH_STUB_RELEASE_AFTER=0
  run release_present "loft-sh/vcluster" "v0.36.1-rc.2"
  [ "$status" -eq 1 ]

  rm -f "${GH_STUB_COUNT_FILE}"
  export GH_STUB_RELEASE_ERRORS=1
  run release_present "loft-sh/vcluster" "v0.36.1-rc.2"
  [ "$status" -eq 2 ]
}

@test "producer_state reports no run, api error and parsed state" {
  source "$SCRIPT"

  export GH_STUB_NO_RUN=1
  run producer_state "loft-sh/vcluster" "release.yaml" "v0.36.1-rc.2"
  [ "$status" -eq 1 ]

  unset GH_STUB_NO_RUN
  export GH_STUB_RUN_ERROR=1
  run producer_state "loft-sh/vcluster" "release.yaml" "v0.36.1-rc.2"
  [ "$status" -eq 2 ]

  unset GH_STUB_RUN_ERROR
  export GH_STUB_RUN_STATUS="completed"
  export GH_STUB_RUN_CONCLUSION="failure"
  run producer_state "loft-sh/vcluster" "release.yaml" "v0.36.1-rc.2"
  [ "$status" -eq 0 ]
  [[ "$output" == "completed|failure|"* ]]

  # An unconcluded run sends JSON null, which jq -r renders as "null". The
  # script compares conclusions as strings, so this must stay non-terminal.
  export GH_STUB_RUN_STATUS="in_progress"
  unset GH_STUB_RUN_CONCLUSION
  run producer_state "loft-sh/vcluster" "release.yaml" "v0.36.1-rc.2"
  [ "$status" -eq 0 ]
  [[ "$output" == "in_progress|null|"* ]]
  run is_terminal "null"
  [ "$status" -ne 0 ]
}

#!/usr/bin/env bats
# Tests for setup-semstat/src/install-semstat.sh
#
# Stubs curl with a local release directory, so the download, the checksum
# verification and the version cross-check all run for real against artifacts
# the test builds.

SCRIPT="$BATS_TEST_DIRNAME/../src/install-semstat.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR

  export GITHUB_OUTPUT="$TEST_DIR/github_output"
  : >"$GITHUB_OUTPUT"

  export GITHUB_PATH="$TEST_DIR/github_path"
  : >"$GITHUB_PATH"

  export RUNNER_TEMP="$TEST_DIR/runner-temp"
  mkdir -p "$RUNNER_TEMP"

  # A release served from disk. RELEASE_DIR/<tag>/<asset> is what curl hands back.
  export RELEASE_DIR="$TEST_DIR/release"
  export SEMSTAT_BASE_URL="file://$RELEASE_DIR"
  export SEMSTAT_VERSION=v1.2.3

  MOCK_DIR="$TEST_DIR/mock"
  mkdir -p "$MOCK_DIR"
  export PATH="$MOCK_DIR:$PATH"

  export CURL_URLS="$TEST_DIR/curl_urls"
  : >"$CURL_URLS"

  # curl: -o <path> <url>. Serves RELEASE_DIR, exiting 22 like a 404 when the
  # asset is not there, and records every URL asked for.
  cat >"$MOCK_DIR/curl" <<'MOCK'
#!/usr/bin/env bash
dest=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >>"$CURL_URLS"
src="${url#file://}"
[ -f "$src" ] || exit 22
cp "$src" "$dest"
MOCK
  chmod +x "$MOCK_DIR/curl"

  export COSIGN_ARGS="$TEST_DIR/cosign_args"
  : >"$COSIGN_ARGS"

  # cosign: records the whole invocation and reports OK. COSIGN_EXIT stands in
  # for a bundle that does not verify.
  cat >"$MOCK_DIR/cosign" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COSIGN_ARGS"
if [ "${COSIGN_EXIT:-0}" -ne 0 ]; then
  echo "Error: no matching signatures" >&2
  exit "$COSIGN_EXIT"
fi
echo "Verified OK" >&2
MOCK
  chmod +x "$MOCK_DIR/cosign"

  publish_release v1.2.3 1.2.3
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Builds a release: an archive holding a semstat that reports $2, plus the
# checksums.txt covering it.
publish_release() {
  local tag="$1" reported="$2" noise="${3-}"
  local version="${tag#v}"
  local dir="$RELEASE_DIR/$tag"
  local staging="$TEST_DIR/staging-$tag"

  mkdir -p "$dir" "$staging"

  cat >"$staging/semstat" <<MOCK
#!/usr/bin/env bash
[ "\$1" = version ] || exit 2
[ -n "$noise" ] && echo "$noise" >&2
echo "$reported"
MOCK
  chmod +x "$staging/semstat"

  # Every platform gets the same archive: the test picks the name the script
  # asks for out of the ones this loop wrote.
  local target
  for target in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
    tar -czf "$dir/semstat_${version}_${target}.tar.gz" -C "$staging" semstat
  done

  (cd "$dir" && sha256sum ./*.tar.gz | sed 's| \./| |' >checksums.txt)

  # The signature bundle is opaque to the script, which only hands it to cosign,
  # so its contents matter no more than that the asset is there to be fetched.
  printf '{"mediaType":"application/vnd.dev.sigstore.bundle+json;version=0.3"}\n' \
    >"$dir/checksums.txt.sigstore.json"
}

# Reads an output back out of GITHUB_OUTPUT.
output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n1
}

# The directories the run put on PATH for the steps that follow it.
path_entries() {
  cat "$GITHUB_PATH"
}

# The assets fetched from the release so far, by name.
requested_assets() {
  sed 's|.*/||' "$CURL_URLS"
}

# The archive name the run asked the release for.
requested_archive() {
  grep -o '[^/]*\.tar\.gz$' "$CURL_URLS" | tail -n1
}

# How many assets have been fetched from the release so far.
download_count() {
  wc -l <"$CURL_URLS"
}

# Stubs uname so the platform mapping can be exercised off this machine.
stub_uname() {
  cat >"$MOCK_DIR/uname" <<MOCK
#!/usr/bin/env bash
case "\$1" in
  -s) echo "$1" ;;
  -m) echo "$2" ;;
esac
MOCK
  chmod +x "$MOCK_DIR/uname"
}

@test "installs the binary and reports where it landed" {
  run "$SCRIPT"

  [ "$status" -eq 0 ]

  binary="$(output_value semstat)"
  [ -x "$binary" ]
  [ "$("$binary" version)" = "1.2.3" ]
}

@test "accepts a version without the leading v" {
  export SEMSTAT_VERSION=1.2.3

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -x "$(output_value semstat)" ]
}

@test "unpacks under RUNNER_TEMP so the runner cleans up after the job" {
  run "$SCRIPT"

  [ "$status" -eq 0 ]
  case "$(output_value semstat)" in
    "$RUNNER_TEMP"/*) ;;
    *) false ;;
  esac
}

@test "fails when the release does not exist" {
  export SEMSTAT_VERSION=v9.9.9

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::could not download"* ]]
  [ -z "$(output_value semstat)" ]
}

@test "fails when the archive does not match its checksum" {
  # Pinned, because the tampering below picks one archive out of the four the
  # release holds and the script has to be asking for that one.
  stub_uname Linux x86_64
  printf 'tampered' >>"$RELEASE_DIR/v1.2.3/semstat_1.2.3_linux_amd64.tar.gz"

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::checksum mismatch"* ]]
  [ -z "$(output_value semstat)" ]
}

@test "fails when checksums.txt covers no archive of ours" {
  grep -v 'amd64' "$RELEASE_DIR/v1.2.3/checksums.txt" >"$TEST_DIR/trimmed"
  mv "$TEST_DIR/trimmed" "$RELEASE_DIR/v1.2.3/checksums.txt"
  stub_uname Linux x86_64

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"lists no semstat_1.2.3_linux_amd64.tar.gz"* ]]
}

@test "fails when the binary reports a different version than was asked for" {
  # A release whose archives are named 1.2.4 but hold a semstat that says 1.2.3,
  # which is what an asset copied between releases would look like.
  publish_release v1.2.4 1.2.3
  export SEMSTAT_VERSION=v1.2.4

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"reports version 1.2.3, expected 1.2.4"* ]]
  [ -z "$(output_value semstat)" ]
}

# The release carries a byte-identical archive under all four names, so these
# assert on the name asked for rather than on the run succeeding: an exit 0 alone
# passes whichever asset the mapping picks.
@test "downloads the linux amd64 archive on an x86 linux runner" {
  stub_uname Linux x86_64

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(requested_archive)" = "semstat_1.2.3_linux_amd64.tar.gz" ]
}

@test "downloads the linux arm64 archive on an arm64 linux runner" {
  stub_uname Linux aarch64

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(requested_archive)" = "semstat_1.2.3_linux_arm64.tar.gz" ]
}

@test "downloads the darwin arm64 archive on apple silicon" {
  stub_uname Darwin arm64

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(requested_archive)" = "semstat_1.2.3_darwin_arm64.tar.gz" ]
}

@test "downloads the darwin amd64 archive on an intel mac" {
  stub_uname Darwin x86_64

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(requested_archive)" = "semstat_1.2.3_darwin_amd64.tar.gz" ]
}

@test "a binary that writes to stderr still installs" {
  publish_release v1.2.5 1.2.5 "warning: something on stderr"
  export SEMSTAT_VERSION=v1.2.5

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -x "$(output_value semstat)" ]
}

@test "a binary reporting a v-prefixed version still installs" {
  publish_release v1.2.6 v1.2.6
  export SEMSTAT_VERSION=v1.2.6

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -x "$(output_value semstat)" ]
}

@test "refuses a platform semstat is not built for" {
  stub_uname Windows_NT x86_64

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::semstat has no build for Windows_NT"* ]]
}

@test "refuses an architecture semstat is not built for" {
  stub_uname Linux ppc64le

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::semstat has no build for ppc64le"* ]]
}

@test "installs the pinned release when SEMSTAT_VERSION is unset" {
  pinned="$(sed -n 's/^DEFAULT_VERSION=//p' "$SCRIPT")"
  [ -n "$pinned" ]

  unset SEMSTAT_VERSION

  run "$SCRIPT"

  # The test serves one release from disk and it is not that one, so the download
  # fails; which release was asked for is what this is about.
  [ "$status" -eq 1 ]
  [[ "$(cat "$CURL_URLS")" == *"/${pinned}/"* ]]
}

@test "fails when GITHUB_PATH is not set" {
  unset GITHUB_PATH

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_PATH is required"* ]]
}

# Refused rather than falling back to /tmp: the install directory carries the
# signature-verified marker, and on a shared /tmp anyone could forge it.
@test "fails when RUNNER_TEMP is not set" {
  unset RUNNER_TEMP

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"RUNNER_TEMP is required"* ]]
  [ ! -s "$CURL_URLS" ]
}

@test "leaves no work directory behind once installed" {
  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -z "$(find "$RUNNER_TEMP" -maxdepth 1 -name 'semstat.*' -print -quit)" ]
}

# The archive and any half-unpacked binary go with it, on every exit path rather
# than only the one that succeeded.
@test "leaves no work directory behind when the install fails" {
  publish_release v1.2.4 1.2.3
  export SEMSTAT_VERSION=v1.2.4

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [ -z "$(find "$RUNNER_TEMP" -maxdepth 1 -name 'semstat.*' -print -quit)" ]
}

@test "refuses a version that is not a semantic version" {
  export SEMSTAT_VERSION=latest

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a semantic version"* ]]
  [ -z "$(output_value semstat)" ]
  [ ! -s "$CURL_URLS" ]
}

@test "a newline in the version cannot forge a workflow command" {
  # The version is echoed back on every failure below, so it has to be refused
  # before it reaches one of those lines rather than folded at each of them.
  export SEMSTAT_VERSION='v0.0.1-nope
::stop-commands::forged'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  ! grep -q '^::stop-commands::' <<<"$output"
}

@test "installs a prerelease version" {
  publish_release v1.4.0-rc.1 1.4.0-rc.1
  export SEMSTAT_VERSION=v1.4.0-rc.1

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$("$(output_value semstat)" version)" = "1.4.0-rc.1" ]
}

@test "refuses an archive whose semstat member is a symlink" {
  local dir="$RELEASE_DIR/v1.5.0"
  local staging="$TEST_DIR/staging-symlink"
  mkdir -p "$dir" "$staging"
  ln -s /bin/echo "$staging/semstat"
  local target
  for target in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
    tar -czf "$dir/semstat_1.5.0_${target}.tar.gz" -C "$staging" semstat
  done
  (cd "$dir" && sha256sum ./*.tar.gz | sed 's| \./| |' >checksums.txt)
  export SEMSTAT_VERSION=v1.5.0

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not a regular file"* ]]
  [ -z "$(output_value semstat)" ]
}

@test "does not reuse a planted binary that this run never verified" {
  # A predictable install path plus a binary that prints the right version was
  # the whole reuse gate before; the marker is what makes it this run's install.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  installed="$(output_value semstat)"
  downloaded="$(download_count)"

  rm -f "$(dirname "$installed")/.verified"
  cat >"$installed" <<'PLANTED'
#!/usr/bin/env bash
[ "$1" = version ] && echo 1.2.3
PLANTED
  chmod +x "$installed"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(download_count)" -gt "$downloaded" ]
  ! grep -q PLANTED "$installed"
}

@test "does not reuse a binary that changed after it was verified" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  installed="$(output_value semstat)"
  downloaded="$(download_count)"

  # Keeps the recorded marker, so only the digest says the binary moved.
  cat >"$installed" <<'PLANTED'
#!/usr/bin/env bash
[ "$1" = version ] && echo 1.2.3
PLANTED
  chmod +x "$installed"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(download_count)" -gt "$downloaded" ]
}

@test "refuses a download root that is not a local release" {
  # Composite steps inherit the job's environment, so this is reachable from a
  # workflow-level env: rather than only from a test.
  export SEMSTAT_BASE_URL=https://example.invalid/releases/download

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"file:// URLs only"* ]]
  [ -z "$(output_value semstat)" ]
  [ ! -s "$CURL_URLS" ]
}

@test "reuses the installed binary rather than downloading the release again" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  first="$(output_value semstat)"
  downloaded="$(download_count)"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value semstat)" = "$first" ]
  [ "$(download_count)" -eq "$downloaded" ]
  [[ "$output" == *"already installed"* ]]
}

@test "downloads again for a version that is not installed yet" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  downloaded="$(download_count)"

  publish_release v1.3.0 1.3.0
  export SEMSTAT_VERSION=v1.3.0

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(download_count)" -gt "$downloaded" ]
  [ "$("$(output_value semstat)" version)" = "1.3.0" ]
}

@test "replaces an installed binary that no longer runs" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Keeps the executable bit, so only running it says the install is unusable.
  printf 'truncated' >"$(output_value semstat)"
  downloaded="$(download_count)"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(download_count)" -gt "$downloaded" ]
  [ "$("$(output_value semstat)" version)" = "1.2.3" ]
}

@test "an archive with no semstat member says so rather than dying on tar's complaint" {
  local dir="$RELEASE_DIR/v1.6.0"
  local staging="$TEST_DIR/staging-nomember"
  mkdir -p "$dir" "$staging"
  echo binary >"$staging/semstat_1.6.0_linux_amd64"
  local target
  for target in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
    tar -czf "$dir/semstat_1.6.0_${target}.tar.gz" -C "$staging" "semstat_1.6.0_linux_amd64"
  done
  (cd "$dir" && sha256sum ./*.tar.gz | sed 's| \./| |' >checksums.txt)
  export SEMSTAT_VERSION=v1.6.0

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::could not unpack semstat"* ]]
  [ -z "$(output_value semstat)" ]
}

@test "a failed install leaves no work directory behind under RUNNER_TEMP" {
  export SEMSTAT_VERSION=v9.9.9

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [ -z "$(find "$RUNNER_TEMP" -maxdepth 1 -name 'semstat.*' -print -quit)" ]
}

@test "a successful install leaves no work directory behind either" {
  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -z "$(find "$RUNNER_TEMP" -maxdepth 1 -name 'semstat.*' -print -quit)" ]
}

# A PATH holding bash, so the shebang resolves, plus the named tools and nothing
# else. Used to take one tool away from the gate at a time.
gate_path() {
  local gate tool src
  gate="$(mktemp -d "$TEST_DIR/gate.XXXXXX")"
  ln -s "$(command -v bash)" "$gate/bash"

  for tool in "$@"; do
    if [ "$tool" = curl ]; then
      ln -s "$MOCK_DIR/curl" "$gate/curl"
      continue
    fi
    src="$(command -v "$tool")"
    ln -s "$src" "$gate/$tool"
  done

  printf '%s' "$gate"
}

@test "a runner without curl says which tool it is missing" {
  run /usr/bin/env "PATH=$(gate_path tar sha256sum)" "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::curl is required to install semstat"* ]]
}

@test "a runner without tar says so before anything is downloaded" {
  run /usr/bin/env "PATH=$(gate_path curl sha256sum)" "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::tar is required to install semstat"* ]]
  [ ! -s "$CURL_URLS" ]
}

@test "a runner with no sha256 tool refuses to install rather than fail mid-verify" {
  # Without the gate this died on `shasum: command not found` with no ::error::
  # line, which reads as a broken action rather than as a runner that cannot
  # verify a download.
  run /usr/bin/env "PATH=$(gate_path curl tar)" "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::sha256sum or shasum is required"* ]]
  [ ! -s "$CURL_URLS" ]
}

# PATH, not just the output: every consumer calls semstat from inside a bash
# function or a `while read` loop, where a step output is not in scope.
@test "puts the directory holding the binary on PATH" {
  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(path_entries)" = "$(dirname "$(output_value semstat)")" ]
}

@test "puts the binary on PATH again when the install is reused" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  installed="$(path_entries)"
  : >"$GITHUB_PATH"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  [ "$(path_entries)" = "$installed" ]
}

@test "leaves the signature alone unless asked" {
  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$(requested_assets)" != *sigstore* ]]
  [ ! -s "$COSIGN_ARGS" ]
}

@test "verifies checksums.txt against the release workflow at the exact tag" {
  export SEMSTAT_VERIFY_SIGNATURE=true

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$(requested_assets)" == *checksums.txt.sigstore.json* ]]
  [[ "$(cat "$COSIGN_ARGS")" == *"verify-blob"* ]]
  [[ "$(cat "$COSIGN_ARGS")" == *"--bundle "*"checksums.txt.sigstore.json"* ]]
  [[ "$(cat "$COSIGN_ARGS")" == *"--certificate-identity=https://github.com/loft-sh/semstat/.github/workflows/release.yaml@refs/tags/v1.2.3"* ]]
  [[ "$(cat "$COSIGN_ARGS")" == *"--certificate-oidc-issuer=https://token.actions.githubusercontent.com"* ]]
}

# A release can carry its archives and checksums.txt and no bundle, so this must
# not be reported as the release being absent.
@test "names the missing signature when the release publishes no bundle" {
  export SEMSTAT_VERIFY_SIGNATURE=true
  rm "$RELEASE_DIR/v1.2.3/checksums.txt.sigstore.json"

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"publishes no checksums.txt.sigstore.json"* ]]
  [[ "$output" != *"check that the release exists"* ]]
  [ -z "$(output_value semstat)" ]
}

@test "fails when cosign does not verify the bundle" {
  export SEMSTAT_VERIFY_SIGNATURE=true
  export COSIGN_EXIT=1

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::cosign could not verify checksums.txt"* ]]
  [[ "$output" == *"no matching signatures"* ]]
  [ -z "$(output_value semstat)" ]
}

# The error names the action, because a workflow that ran the script itself is
# the only way to reach a verify-signature request with no cosign on PATH.
#
# PATH is narrowed to a farm holding only what the script needs rather than
# trimmed of the mock, so the result does not depend on whether the machine
# running the tests happens to have a real cosign installed.
@test "fails when verification is asked for and cosign is not installed" {
  export SEMSTAT_VERIFY_SIGNATURE=true

  farm="$TEST_DIR/no-cosign"
  mkdir -p "$farm"
  # `|| continue` rather than `&&`: as the last statement of the loop body, a
  # miss would otherwise carry its status out of the loop and trip bats' set -e
  # on a machine without one of these, failing the test at an unrelated line.
  # sha256sum and shasum are both listed because the script takes either.
  for tool in bash env uname mktemp awk tar chmod mv rm cat cut tr sha256sum shasum; do
    real="$(command -v "$tool")" || continue
    ln -sf "$real" "$farm/$tool"
  done
  ln -sf "$MOCK_DIR/curl" "$farm/curl"

  # Narrowed for the script only. Narrowing the test's own PATH would leave bats
  # unable to find the tools it cleans up with once teardown removes the farm.
  run env PATH="$farm" "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::verify-signature needs cosign on PATH"* ]]
  [ -z "$(output_value semstat)" ]
}

@test "refuses a verify-signature value that is neither true nor false" {
  export SEMSTAT_VERIFY_SIGNATURE=yes

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"verify-signature takes true or false; got yes"* ]]
  [ ! -s "$CURL_URLS" ]
}

# A step asking for verification cannot be served by whatever an earlier
# unverified step left in the shared install directory.
@test "re-installs over an install that was not signature-verified" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  downloaded="$(download_count)"

  export SEMSTAT_VERIFY_SIGNATURE=true

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(download_count)" -gt "$downloaded" ]
  [ -s "$COSIGN_ARGS" ]
}

@test "reuses an install that was signature-verified" {
  export SEMSTAT_VERIFY_SIGNATURE=true

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  downloaded="$(download_count)"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  [ "$(download_count)" -eq "$downloaded" ]
}

# An unverified re-install must not inherit the earlier run's claim: the next
# verifying step would otherwise reuse a binary nothing verified.
@test "drops the verified marker when a later run does not verify" {
  export SEMSTAT_VERIFY_SIGNATURE=true
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  unset SEMSTAT_VERIFY_SIGNATURE
  # Only running it says the install is unusable, so this forces a re-install
  # while leaving the marker from the verified run in place.
  printf 'truncated' >"$(output_value semstat)"
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  export SEMSTAT_VERIFY_SIGNATURE=true
  downloaded="$(download_count)"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(download_count)" -gt "$downloaded" ]
}

@test "a checksums.txt with CRLF line endings still verifies the archive" {
  # The \r is not whitespace to awk, so unstripped it stayed on the asset name
  # and the lookup missed, blaming the release for a missing archive that was
  # right there.
  sed 's/$/\r/' "$RELEASE_DIR/v1.2.3/checksums.txt" >"$TEST_DIR/crlf"
  mv "$TEST_DIR/crlf" "$RELEASE_DIR/v1.2.3/checksums.txt"

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -x "$(output_value semstat)" ]
}

@test "a RUNNER_TEMP that cannot be worked in says so rather than dying on mktemp" {
  export RUNNER_TEMP="$TEST_DIR/never-created"
  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::could not create a working directory under RUNNER_TEMP"* ]]
}

# An untouched `version:` input arrives as an empty string rather than unset, and
# the pin lives in the script so the action and a sibling action running that
# script off github.action_path cannot install different releases.
@test "installs the pinned release when the version input is empty" {
  pinned="$(sed -n 's/^DEFAULT_VERSION=//p' "$SCRIPT")"
  [ -n "$pinned" ]

  export SEMSTAT_VERSION=""
  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$(cat "$CURL_URLS")" == *"/${pinned}/"* ]]
}

# The marker is cleared before the binary is moved into place, so a run that dies
# in between cannot leave this run's unverified download under an earlier run's
# claim. Failing the move is how that window is reached from a test.
@test "clears an earlier verified claim even when the install does not complete" {
  export SEMSTAT_VERIFY_SIGNATURE=true
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  marker="$(dirname "$(output_value semstat)")/.signature-verified"
  [ -f "$marker" ]

  unset SEMSTAT_VERIFY_SIGNATURE
  # Only running it says the install is unusable, so this forces a re-install.
  printf 'truncated' >"$(output_value semstat)"

  break_dir="$TEST_DIR/break"
  mkdir -p "$break_dir"
  cat >"$break_dir/mv" <<'MOCK'
#!/usr/bin/env bash
echo "mv: interrupted" >&2
exit 1
MOCK
  chmod +x "$break_dir/mv"

  run env PATH="$break_dir:$PATH" "$SCRIPT"

  [ "$status" -ne 0 ]
  [ ! -f "$marker" ]
}

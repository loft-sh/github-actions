#!/usr/bin/env bash
# Downloads the semstat release binary, verifies it against the release
# checksums, puts it on PATH and reports where it landed.
#
# Emits one GitHub Actions step output:
#
#   semstat   absolute path to the verified, executable binary
#
# and, unless asked not to, appends the directory holding it to GITHUB_PATH,
# because most consumers call semstat from inside a bash function or a `while
# read` loop, where a step output is not in scope. The output is kept as well,
# for a caller that would rather name the binary than depend on PATH ordering.
#
# Required environment:
#   GITHUB_OUTPUT     standard GitHub Actions step output file.
#   GITHUB_PATH       standard GitHub Actions path file.
#   RUNNER_TEMP       where to unpack. Per-job and cleared by the runner.
#
# Optional environment:
#   SEMSTAT_VERSION   release tag to install, with or without a leading "v".
#                     Empty or unset installs DEFAULT_VERSION below.
#   SEMSTAT_VERIFY_SIGNATURE  "true" to cosign-verify checksums.txt against the
#                             release workflow before trusting it. Needs cosign
#                             on PATH; the action installs it when asked.
#   SEMSTAT_BASE_URL  file:// release download root. For the tests; see below.
#   SEMSTAT_SKIP_PATH "true" to report the binary through the step output only
#                     and leave GITHUB_PATH alone. For a caller that names the
#                     binary and has no use for a change to the job's PATH.
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
# Not defaulted to /tmp: RUNNER_TEMP is private to one job, and the install
# directory below is a name anyone could predict. On a runner with a shared
# writable /tmp, the fallback would let another user plant a binary there for
# the reuse check to adopt, or plant an empty signature marker over it so that a
# step asking to verify takes the cache-hit path and never runs cosign.
: "${RUNNER_TEMP:?RUNNER_TEMP is required; this action expects a GitHub Actions runner}"

# Checked up front rather than where each is first reached. A runner missing one
# of these otherwise dies partway through on the tool's own bare complaint, with
# no ::error:: line naming what the runner has to have; the download and the
# checksum it is verified against are the same step as far as the caller can see,
# so "this runner cannot verify a download" has to be said before either starts.
for tool in curl tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::${tool} is required to install semstat and is not on PATH"
    exit 1
  fi
done

if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "::error::sha256sum or shasum is required to verify the semstat download and neither is on PATH"
  exit 1
fi

# A workflow command ends at a newline, so anything the downloaded binary prints
# has to be folded onto one line before it is echoed back.
fold_lines() {
  printf '%s' "$1" | tr '\r\n' '  '
}

# One of the two is known to be on PATH by the gate above.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

BASE_URL="https://github.com/loft-sh/semstat/releases/download"

# The pin lives here rather than in action.yml because both entry points reach
# this script: the action, and a sibling action in this repository running it off
# github.action_path to avoid pinning a sibling by SHA. One line to bump, and no
# way for the two to install different releases.
# renovate: datasource=github-releases depName=loft-sh/semstat
DEFAULT_VERSION=v0.0.2

# The workflow that publishes the release, and so the identity its signatures
# carry. Verified at the exact tag rather than at a branch or a glob: a bundle
# signed by this workflow on any other ref does not attest this release.
SIGNING_WORKFLOW="https://github.com/loft-sh/semstat/.github/workflows/release.yaml"
OIDC_ISSUER="https://token.actions.githubusercontent.com"

# The tests serve a release from disk. A remote override is refused rather than
# ignored, because composite steps inherit the job's environment: a workflow-level
# env: or an earlier step writing GITHUB_ENV would otherwise repoint which
# executable this action runs, and checksums.txt is fetched from the same root, so
# the substituted binary would verify against a substituted manifest.
if [ -n "${SEMSTAT_BASE_URL-}" ]; then
  case "$SEMSTAT_BASE_URL" in
    file://*) BASE_URL="$SEMSTAT_BASE_URL" ;;
    *)
      echo "::error::SEMSTAT_BASE_URL overrides the download root for file:// URLs only; got $(fold_lines "$SEMSTAT_BASE_URL")"
      exit 1
      ;;
  esac
fi

# Anything but the two booleans is a typo rather than a no, and reading a typo as
# "do not verify" would answer a request for the stricter check with the weaker one.
case "${SEMSTAT_VERIFY_SIGNATURE:-false}" in
  true) verify_signature=true ;;
  false) verify_signature=false ;;
  *)
    echo "::error::verify-signature takes true or false; got $(fold_lines "$SEMSTAT_VERIFY_SIGNATURE")"
    exit 1
    ;;
esac

# Read the same way as verify-signature, and for the same reason: a typo taken
# for a no would leave the job's PATH changed under a caller that asked for it
# not to be.
case "${SEMSTAT_SKIP_PATH:-false}" in
  true) skip_path=true ;;
  false) skip_path=false ;;
  *)
    echo "::error::SEMSTAT_SKIP_PATH takes true or false; got $(fold_lines "$SEMSTAT_SKIP_PATH")"
    exit 1
    ;;
esac

requested="${SEMSTAT_VERSION:-$DEFAULT_VERSION}"
case "$requested" in
  v*) tag="$requested" ;;
  *) tag="v${requested}" ;;
esac
version="${tag#v}"

# The version reaches both the download URL and, on every failure below, a
# workflow command. Checking its shape here is what keeps a newline in the input
# from closing an ::error:: line and having the rest read as a command of its
# own, and what keeps path segments out of the URL; the echoes downstream carry
# it unfolded because it got through this.
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "::error::the version to install must be a semantic version, with or without a leading v; got $(fold_lines "$requested")"
  exit 1
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *)
    echo "::error::semstat has no build for $(uname -s); this action needs a Linux or macOS runner"
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    echo "::error::semstat has no build for $(uname -m)"
    exit 1
    ;;
esac

archive="semstat_${version}_${os}_${arch}.tar.gz"

# One directory per release and platform, so a job that reports on several
# versions downloads the release once instead of once per step. RUNNER_TEMP is
# per-job and the runner clears it, so nothing is carried into another job.
install_dir="${RUNNER_TEMP}/semstat-${version}-${os}-${arch}"
binary="${install_dir}/semstat"

# Written only after the checksum and the version cross-check passed, and holds
# the digest of the binary they passed for. Reuse asks the marker rather than
# the binary, because a binary that prints the right version proves nothing
# about the rest of itself.
marker="${install_dir}/.verified"

# A second marker, because the two questions are different: the digest says this
# is the binary that passed, and this says the release it came out of was
# signature-checked. A step asking to verify is not handed an install an earlier
# unverified step left behind.
verified_marker="${install_dir}/.signature-verified"

# PATH for the callers that reach semstat from a function or a loop, the output
# for the ones that would rather be explicit about which binary they mean. Both
# are the whole answer this step gives the next one, so a write that did not land
# has to fail the step rather than hand the caller an empty SEMSTAT_BIN.
report_install() {
  if ! echo "semstat=${binary}" >>"$GITHUB_OUTPUT"; then
    echo "::error::could not write the semstat path to GITHUB_OUTPUT"
    exit 1
  fi
  if [ "$skip_path" = true ]; then
    return
  fi
  if ! printf '%s\n' "$install_dir" >>"$GITHUB_PATH"; then
    echo "::error::could not add ${install_dir} to GITHUB_PATH"
    exit 1
  fi
}

# An installed binary is reused only if this script verified it earlier in this
# job, it has not changed since, it still runs and agrees about its version, and
# it was verified as strictly as this step asks.
if [ -x "$binary" ] &&
  recorded="$(cat "$marker" 2>/dev/null)" && [ -n "$recorded" ] &&
  [ "$recorded" = "$(sha256_of "$binary")" ] &&
  cached="$("$binary" version 2>/dev/null)" && [ "${cached#v}" = "$version" ] &&
  { [ "$verify_signature" = false ] || [ -f "$verified_marker" ]; }; then
  report_install
  echo "semstat ${version} already installed at ${binary}"
  exit 0
fi

if [ "$verify_signature" = true ] && ! command -v cosign >/dev/null 2>&1; then
  echo "::error::verify-signature needs cosign on PATH; the setup-semstat action installs it, so this is reachable only by running the script directly"
  exit 1
fi

if ! work="$(mktemp -d "${RUNNER_TEMP}/semstat.XXXXXX")" || [ -z "$work" ]; then
  echo "::error::could not create a working directory under RUNNER_TEMP to download semstat into"
  exit 1
fi
# On a trap rather than at the end, so a failed download or a checksum mismatch
# does not leave the archive it failed on behind under RUNNER_TEMP.
trap 'rm -rf "$work"' EXIT

# checksums.txt is fetched alongside the archive rather than pinned here, because
# the version is an input. It proves the download arrived intact and that the
# asset name resolved inside the release we asked for, and `semstat version`
# below proves we unpacked semstat. It says nothing about who published that
# release, which is the separate question SEMSTAT_VERIFY_SIGNATURE answers.
for asset in "$archive" checksums.txt; do
  status=0
  curl -fsSL --retry 3 --retry-connrefused --connect-timeout 10 --max-time 120 -o "${work}/${asset}" "${BASE_URL}/${tag}/${asset}" || status=$?
  if [ "$status" -ne 0 ]; then
    # curl's status, because a missing release (22) and a runner without curl,
    # DNS or egress otherwise read as the same sentence.
    echo "::error::could not download ${asset} for semstat ${tag}: curl exited ${status}"
    exit 1
  fi
done

# Fetched on its own rather than in the loop above, because an absent bundle is a
# different failure than an absent release and must not be reported as one.
# semstat signs at the end of goreleaser's publish phase, so a Fulcio or Rekor
# outage there leaves the release published with the archives but no provenance.
if [ "$verify_signature" = true ]; then
  bundle=checksums.txt.sigstore.json
  status=0
  curl -fsSL --retry 3 --retry-connrefused --connect-timeout 10 --max-time 120 -o "${work}/${bundle}" "${BASE_URL}/${tag}/${bundle}" || status=$?
  # 22 is curl's HTTP-error status, so the release answered and does not carry
  # the asset. Any other status is this runner not reaching it, and telling that
  # runner to re-dispatch semstat's release workflow sends it after the wrong
  # repair.
  if [ "$status" -eq 22 ]; then
    echo "::error::semstat ${tag} publishes no ${bundle}, so its signature cannot be verified; the release may have been published through a signing outage, which a re-dispatch of its release workflow repairs"
    exit 1
  elif [ "$status" -ne 0 ]; then
    echo "::error::could not download ${bundle} for semstat ${tag}: curl exited ${status}"
    exit 1
  fi
fi

# Before checksums.txt is read rather than after: the signature is what says this
# manifest came from the release workflow, and every integrity claim below rests
# on the manifest.
if [ "$verify_signature" = true ]; then
  identity="${SIGNING_WORKFLOW}@refs/tags/${tag}"
  if ! cosign_output="$(cosign verify-blob "${work}/checksums.txt" \
    --bundle "${work}/checksums.txt.sigstore.json" \
    --certificate-identity="$identity" \
    --certificate-oidc-issuer="$OIDC_ISSUER" 2>&1)"; then
    echo "::error::cosign could not verify checksums.txt for semstat ${tag} as ${identity}: $(fold_lines "$cosign_output")"
    exit 1
  fi
  echo "cosign verified checksums.txt for semstat ${tag} as ${identity}"
fi

# Pick out our line rather than running `sha256sum -c` over the whole file:
# checksums.txt covers every archive and SBOM in the release and only one of
# them was downloaded, and an absent line has to be an error rather than the
# nothing-to-check pass that --ignore-missing would give it.
# The trailing \r is stripped because it is not whitespace to awk and would
# otherwise stay on the name, turning a CRLF-served manifest into "lists no
# semstat_..." — a sentence that points at the release rather than at the file.
expected="$(awk -v want="$archive" '{ sub(/\r$/, "", $2); if ($2 == want || $2 == "*" want) print $1 }' "${work}/checksums.txt")"
if [ -z "$expected" ]; then
  echo "::error::checksums.txt for semstat ${tag} lists no ${archive}"
  exit 1
fi

if ! actual="$(sha256_of "${work}/${archive}")" || [ -z "$actual" ]; then
  echo "::error::could not compute the checksum of the downloaded ${archive}"
  exit 1
fi

if [ "$actual" != "$expected" ]; then
  echo "::error::checksum mismatch for ${archive}: got ${actual}, expected ${expected}"
  exit 1
fi

# The member name is part of the release layout, not of anything checked above,
# so an upstream goreleaser change that wraps the binary in a directory or
# renames it has to say so rather than kill the step on tar's bare complaint.
if ! tar -xzf "${work}/${archive}" -C "$work" semstat 2>"${work}/tar.err"; then
  echo "::error::could not unpack semstat out of ${archive}: $(fold_lines "$(cat "${work}/tar.err")")"
  exit 1
fi

# chmod and the version check below both follow a symlink, so an archive whose
# semstat member is one would have them land on whatever it points at.
if [ -L "${work}/semstat" ] || [ ! -f "${work}/semstat" ]; then
  echo "::error::the semstat member of ${archive} is not a regular file"
  exit 1
fi

if ! chmod +x "${work}/semstat"; then
  echo "::error::could not make the semstat unpacked out of ${archive} executable"
  exit 1
fi

# A binary that runs and agrees about its own version rules out an archive that
# unpacked to something else. stdout only: a stray line on stderr would otherwise
# be compared as though it were part of the version, and rejected as a mismatch.
if ! reported="$("${work}/semstat" version 2>"${work}/version.err")"; then
  echo "::error::the downloaded semstat did not run: $(fold_lines "$(cat "${work}/version.err")")"
  exit 1
fi

# The v is tolerated because which release this is, is the question; how it
# spells the number is not part of any contract we hold semstat to.
if [ "${reported#v}" != "$version" ]; then
  echo "::error::downloaded semstat reports version $(fold_lines "$reported"), expected ${version}"
  exit 1
fi

# Moved into place only once verified, so nothing half-installed is left behind
# for the reuse check above to find.
if ! mkdir -p "$install_dir"; then
  echo "::error::could not create ${install_dir} to install semstat into"
  exit 1
fi

# An older signature claim is dropped before this run's binary lands rather than
# after. The reverse order leaves a window where a run killed mid-install has
# replaced the binary but not the marker, so an unverified download sits under an
# earlier run's claim and the reuse check above hands it to a step that asked to
# verify.
if [ "$verify_signature" = false ] && ! rm -f "$verified_marker"; then
  echo "::error::could not drop the earlier signature claim at ${verified_marker}, which would leave this unverified install standing under it for a later step asking to verify"
  exit 1
fi

if ! mv "${work}/semstat" "$binary" || ! sha256_of "$binary" >"$marker"; then
  # The digest marker is written last, so a failure part-way leaves an install
  # the reuse check above will not adopt.
  echo "::error::could not install the verified semstat to ${binary}"
  exit 1
fi

# Written after the binary, so the marker never claims more than what is
# installed. A claim that could not be written has to fail the step: every later
# step asking to verify would otherwise re-download for the whole job.
if [ "$verify_signature" = true ] && ! : >"$verified_marker"; then
  echo "::error::could not record that semstat ${tag} was signature-verified at ${verified_marker}"
  exit 1
fi

report_install
echo "semstat ${version} installed at ${binary}"

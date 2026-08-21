#!/usr/bin/env bash
# Downloads the semstat release binary, verifies it against the release
# checksums, and reports where it landed.
#
# Emits one GitHub Actions step output:
#
#   semstat   absolute path to the verified, executable binary
#
# Required environment:
#   SEMSTAT_VERSION   release tag to install, with or without a leading "v".
#   GITHUB_OUTPUT     standard GitHub Actions step output file.
#   RUNNER_TEMP       where to unpack. Per-job and cleared by the runner.
#
# Optional environment:
#   SEMSTAT_BASE_URL  file:// release download root. For the tests; see below.
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${SEMSTAT_VERSION:?semstat-version is required}"
# Not defaulted to /tmp: RUNNER_TEMP is private to one job, and the install
# directory below is a name anyone could predict. On a runner with a shared
# writable /tmp, the fallback would let another user plant a binary there for
# the reuse check to adopt.
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

# Named here even though nothing below uses it: jq is what the reporting step of
# this composite reads semstat's output with, and the caller cannot run one step
# without the other. Said before the download rather than after it, so a runner
# missing jq is told so instead of paying for an install it cannot use.
if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required to read semstat's output and is not on PATH"
  exit 1
fi

# A workflow command ends at a newline, so anything the downloaded binary prints
# has to be folded onto one line before it is echoed back.
fold_lines() {
  printf '%s' "$1" | tr '\r\n' '  '
}

# The path is the whole answer this step gives the next one, so a write that did
# not land has to fail the step rather than hand the caller an empty SEMSTAT_BIN.
emit_path() {
  if ! echo "semstat=${binary}" >>"$GITHUB_OUTPUT"; then
    echo "::error::could not write the semstat path to GITHUB_OUTPUT"
    exit 1
  fi
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

case "$SEMSTAT_VERSION" in
  v*) tag="$SEMSTAT_VERSION" ;;
  *) tag="v${SEMSTAT_VERSION}" ;;
esac
version="${tag#v}"

# The version reaches both the download URL and, on every failure below, a
# workflow command. Checking its shape here is what keeps a newline in the input
# from closing an ::error:: line and having the rest read as a command of its
# own, and what keeps path segments out of the URL; the echoes downstream carry
# it unfolded because it got through this.
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "::error::semstat-version must be a semantic version, with or without a leading v; got $(fold_lines "$SEMSTAT_VERSION")"
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

# An installed binary is reused only if this script verified it earlier in this
# job, it has not changed since, and it still runs and agrees about its version.
if [ -x "$binary" ] &&
  recorded="$(cat "$marker" 2>/dev/null)" && [ -n "$recorded" ] &&
  [ "$recorded" = "$(sha256_of "$binary")" ] &&
  cached="$("$binary" version 2>/dev/null)" && [ "${cached#v}" = "$version" ]; then
  emit_path
  echo "semstat ${version} already installed at ${binary}"
  exit 0
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
# below proves we unpacked semstat. It is not a signature check and is not meant
# to be one: semstat is ours, so the release is trusted and this catches a bad
# transfer rather than an untrusted publisher.
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
if ! mkdir -p "$install_dir" ||
  ! mv "${work}/semstat" "$binary" ||
  ! sha256_of "$binary" >"$marker"; then
  # The marker is written last, so a failure part-way leaves an install the reuse
  # check above will not adopt.
  echo "::error::could not install the verified semstat to ${binary}"
  exit 1
fi

emit_path
echo "semstat ${version} installed at ${binary}"

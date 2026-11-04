#!/usr/bin/env bash
# Frees disk space on a GitHub-hosted Ubuntu runner by removing preinstalled
# toolchains and caches the job does not need. Each INPUT_* flag is "true"
# (remove) or "false" (keep); unset flags default to "true".
#
# FDS_ROOT prefixes every removed path so the tests can run against a scratch
# directory instead of the real filesystem.
set -euo pipefail

root="${FDS_ROOT:-}"

# Large apt packages removed when INPUT_LARGE_PACKAGES is true, one apt-get
# call each so a pattern that matches nothing does not block the rest.
large_packages=(
  '^aspnetcore-.*'
  '^dotnet-.*'
  '^llvm-.*'
  'php.*'
  '^mongodb-.*'
  '^mysql-.*'
  azure-cli
  google-chrome-stable
  firefox
  powershell
  mono-devel
  libgl1-mesa-dri
  google-cloud-sdk
  google-cloud-cli
)

# is_enabled succeeds when the flag is "true"; any other value keeps the item.
is_enabled() {
  [ "${1:-true}" = "true" ]
}

# remove_dirs deletes each path under the optional FDS_ROOT prefix.
remove_dirs() {
  local path
  for path in "$@"; do
    sudo rm -rf "${root}${path}"
  done
}

# report prints the space left on the root filesystem.
report() {
  echo "$1: $(df -h "${root:-/}" | awk 'NR==2 {print $4}') available on /"
}

# remove_large_packages uninstalls the large apt packages, warning on misses.
remove_large_packages() {
  local pattern
  for pattern in "${large_packages[@]}"; do
    sudo apt-get remove -y --fix-missing "$pattern" >/dev/null 2>&1 ||
      echo "::warning::apt-get remove ${pattern} failed; continuing"
  done
  sudo apt-get autoremove -y >/dev/null 2>&1 || echo "::warning::apt-get autoremove failed; continuing"
  sudo apt-get clean || echo "::warning::apt-get clean failed; continuing"
}

report "Before"

if is_enabled "${INPUT_ANDROID:-true}"; then
  echo "Removing the Android SDK"
  remove_dirs /usr/local/lib/android
fi

if is_enabled "${INPUT_DOTNET:-true}"; then
  echo "Removing .NET"
  remove_dirs /usr/share/dotnet
fi

if is_enabled "${INPUT_HASKELL:-true}"; then
  echo "Removing Haskell"
  remove_dirs /opt/ghc /usr/local/.ghcup
fi

if is_enabled "${INPUT_TOOL_CACHE:-true}"; then
  echo "Removing the hosted tool cache"
  remove_dirs "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}"
fi

if is_enabled "${INPUT_LARGE_PACKAGES:-true}"; then
  echo "Removing large apt packages"
  remove_large_packages
fi

if is_enabled "${INPUT_DOCKER_IMAGES:-true}"; then
  echo "Pruning Docker images"
  docker image prune --all --force >/dev/null || echo "::warning::docker image prune failed; continuing"
fi

if is_enabled "${INPUT_SWAP_STORAGE:-true}"; then
  echo "Removing swap storage"
  sudo swapoff -a || echo "::warning::swapoff failed; continuing"
  sudo rm -f "${root}/mnt/swapfile"
fi

report "After"

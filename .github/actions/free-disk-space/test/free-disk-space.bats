#!/usr/bin/env bats
# Tests for free-disk-space.sh. Paths live under a scratch FDS_ROOT and
# sudo, apt-get, docker and swapoff are stubs that log their arguments.

SCRIPT="${BATS_TEST_DIRNAME}/../src/free-disk-space.sh"

setup() {
  export FDS_ROOT="${BATS_TEST_TMPDIR}/root"
  export AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
  export CALLS="${BATS_TEST_TMPDIR}/calls.log"
  : >"$CALLS"

  for dir in /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache /mnt; do
    mkdir -p "${FDS_ROOT}${dir}"
  done
  touch "${FDS_ROOT}/mnt/swapfile"

  stubs="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stubs"
  printf '#!/usr/bin/env bash\nexec "$@"\n' >"${stubs}/sudo"
  for cmd in apt-get docker swapoff; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n' "$cmd" >"${stubs}/${cmd}"
  done
  chmod +x "${stubs}"/*
  export PATH="${stubs}:${PATH}"

  unset INPUT_ANDROID INPUT_DOTNET INPUT_HASKELL INPUT_TOOL_CACHE \
    INPUT_LARGE_PACKAGES INPUT_DOCKER_IMAGES INPUT_SWAP_STORAGE
}

@test "defaults remove every toolchain, prune images and drop swap" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  for dir in /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache; do
    [ ! -e "${FDS_ROOT}${dir}" ]
  done
  [ ! -e "${FDS_ROOT}/mnt/swapfile" ]
  grep -q "apt-get remove -y --fix-missing ^dotnet-.*" "$CALLS"
  grep -q "docker image prune --all --force" "$CALLS"
  grep -q "swapoff -a" "$CALLS"
}

@test "tool-cache false keeps the hosted tool cache and removes the rest" {
  INPUT_TOOL_CACHE=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "${FDS_ROOT}/opt/hostedtoolcache" ]
  [ ! -e "${FDS_ROOT}/usr/share/dotnet" ]
  [ ! -e "${FDS_ROOT}/usr/local/lib/android" ]
}

@test "large-packages false skips apt-get entirely" {
  INPUT_LARGE_PACKAGES=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q "^apt-get" "$CALLS"
  grep -q "docker image prune" "$CALLS"
}

@test "every flag false leaves the runner untouched" {
  INPUT_ANDROID=false INPUT_DOTNET=false INPUT_HASKELL=false INPUT_TOOL_CACHE=false \
    INPUT_LARGE_PACKAGES=false INPUT_DOCKER_IMAGES=false INPUT_SWAP_STORAGE=false \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  for dir in /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache; do
    [ -d "${FDS_ROOT}${dir}" ]
  done
  [ -e "${FDS_ROOT}/mnt/swapfile" ]
  [ ! -s "$CALLS" ]
}

@test "a failing apt-get pattern warns and the cleanup carries on" {
  printf '#!/usr/bin/env bash\necho "apt-get $*" >>"$CALLS"\n[[ "$*" != *mysql* ]]\n' >"${BATS_TEST_TMPDIR}/bin/apt-get"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::apt-get remove ^mysql-.* failed; continuing"* ]]
  grep -q "apt-get remove -y --fix-missing google-cloud-cli" "$CALLS"
  grep -q "docker image prune" "$CALLS"
}

@test "a missing docker daemon warns instead of failing the job" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/docker"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::docker image prune failed; continuing"* ]]
  [ ! -e "${FDS_ROOT}/mnt/swapfile" ]
}

#!/usr/bin/env bats

setup() {
  export HEAD_SHA=0123456789abcdef0123456789abcdef01234567
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  export PATH="$BATS_TEST_TMPDIR:$PATH"
  ACTION_DIR="$BATS_TEST_DIRNAME/.."
  for cmd in git just gcloud docker; do
    cat > "$BATS_TEST_TMPDIR/$cmd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >> "$CALLS"
if [[ $(basename "$0") == git ]]; then printf '%s\n' "${CHECKOUT_SHA:-$HEAD_SHA}"; fi
if [[ $(basename "$0") == docker && ${FAIL_PUSH:-0} == 1 ]]; then exit 1; fi
STUB
    chmod +x "$BATS_TEST_TMPDIR/$cmd"
  done
}

@test 'build uses the private SHA tag and disables UI' {
  run bash "$ACTION_DIR/src/build.sh"
  [ "$status" -eq 0 ]
  grep -Fx "just build-image europe-west3-docker.pkg.dev/loft-prod/ui-verifier/platform:$HEAD_SHA false" "$CALLS"
}

@test 'rejects invalid or mismatched checkout before building' {
  export CHECKOUT_SHA=bad
  run bash "$ACTION_DIR/src/build.sh"
  [ "$status" -ne 0 ]
  ! grep -q '^just ' "$CALLS"
  HEAD_SHA='bad' run bash "$ACTION_DIR/src/build.sh"
  [ "$status" -ne 0 ]
}

@test 'push configures the registry and returns the published ref' {
  run bash "$ACTION_DIR/src/push.sh"
  [ "$status" -eq 0 ]
  grep -Fx 'gcloud auth configure-docker europe-west3-docker.pkg.dev --quiet' "$CALLS"
  grep -Fx "docker push europe-west3-docker.pkg.dev/loft-prod/ui-verifier/platform:$HEAD_SHA" "$CALLS"
  grep -Fx "image=europe-west3-docker.pkg.dev/loft-prod/ui-verifier/platform:$HEAD_SHA" "$GITHUB_OUTPUT"
}

@test 'failed push does not publish an output' {
  export FAIL_PUSH=1
  run bash "$ACTION_DIR/src/push.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

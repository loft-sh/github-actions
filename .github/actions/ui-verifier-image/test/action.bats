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

@test 'split build and push entries run the shared scripts in the same job' {
  for entry in build push; do
    export GITHUB_ACTION_PATH="$ACTION_DIR/$entry"
    command=$(sed -n 's/^      run: //p' "$GITHUB_ACTION_PATH/action.yml")
    [ -n "$command" ]
    run bash -ec "$command"
    [ "$status" -eq 0 ]
  done

  image="europe-west3-docker.pkg.dev/loft-prod/ui-verifier/platform:$HEAD_SHA"
  diff -u - "$CALLS" <<EXPECTED
git rev-parse HEAD
just build-image $image false
gcloud auth configure-docker europe-west3-docker.pkg.dev --quiet
docker push $image
EXPECTED
  grep -Fx "image=$image" "$GITHUB_OUTPUT"
}

@test 'documented gate admits only a current same-repository SHA from a writer' {
  sed -n '/          set -euo pipefail/,/          echo "sha=\$approved_sha"/s/^          //p' "$ACTION_DIR/README.md" > "$BATS_TEST_TMPDIR/gate.sh"
  export COMMENT="/publish-ui-image $HEAD_SHA" ACTOR=reviewer PR=12 REPO=loft-sh/loft-enterprise
  export PERMISSION=write PR_STATE=open REPO_ID=246071526 PR_SHA="$HEAD_SHA"
  cat > "$BATS_TEST_TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
if [[ $* == *collaborators* ]]; then
  printf '%s\n' "$PERMISSION"
else
  jq -n --arg state "$PR_STATE" --argjson id "$REPO_ID" --arg sha "$PR_SHA" '{state:$state,head:{repo:{id:$id},sha:$sha},base:{repo:{id:246071526}}}'
fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/gh"
  run bash "$BATS_TEST_TMPDIR/gate.sh"
  [ "$status" -eq 0 ]
  grep -Fx "sha=$HEAD_SHA" "$GITHUB_OUTPUT"
  for scenario in fork unauthorized stale closed; do
    rm -f "$GITHUB_OUTPUT"
    export PERMISSION=write PR_STATE=open REPO_ID=246071526 PR_SHA="$HEAD_SHA"
    case "$scenario" in
      fork) REPO_ID=42 ;;
      unauthorized) PERMISSION=read ;;
      stale) PR_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
      closed) PR_STATE=closed ;;
    esac
    run bash "$BATS_TEST_TMPDIR/gate.sh"
    [ "$status" -eq 0 ]
    [ ! -s "$GITHUB_OUTPUT" ]
  done
}

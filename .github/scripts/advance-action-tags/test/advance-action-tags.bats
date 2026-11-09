#!/usr/bin/env bats

SCRIPT="$BATS_TEST_DIRNAME/../advance-action-tags.sh"

setup() {
  TEST_ROOT=$(mktemp -d)
  REMOTE="$TEST_ROOT/remote.git"
  WORK="$TEST_ROOT/work"
  MOCK="$TEST_ROOT/bin"
  mkdir -p "$MOCK"
  git init --bare --initial-branch=main "$REMOTE" >/dev/null
  git clone "$REMOTE" "$WORK" >/dev/null 2>&1
  git -C "$WORK" config user.name Test
  git -C "$WORK" config user.email test@example.com
  mkdir -p "$WORK/.github/actions/example-action"
  mkdir -p "$WORK/.github/actions/second-action"
  printf 'name: example\n' > "$WORK/.github/actions/example-action/action.yml"
  printf 'name: second\n' > "$WORK/.github/actions/second-action/action.yml"
  git -C "$WORK" add .
  git -C "$WORK" commit -m initial >/dev/null
  OLD_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" tag example-action/v2 "$OLD_SHA"
  git -C "$WORK" tag -a example-action/v4 "$OLD_SHA" -m 'v4 release'
  git -C "$WORK" tag second-action/v1 "$OLD_SHA"
  OLD_V4_OID=$(git -C "$WORK" rev-parse refs/tags/example-action/v4)
  git -C "$WORK" push origin main --tags >/dev/null 2>&1

  printf 'name: example\n# updated\n' > "$WORK/.github/actions/example-action/action.yml"
  git -C "$WORK" commit -am update >/dev/null
  MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" push origin main >/dev/null 2>&1

  export GH_FILES_JSON='[[{"filename":".github/actions/example-action/action.yml"}]]'
  export GH_TOKEN=test-token
  export GH_COMMIT_CALLS="$TEST_ROOT/commit-calls"
  export GITHUB_EVENT_PATH="$TEST_ROOT/event.json"
  export GITHUB_REPOSITORY=owner/repo
  export ADVANCE_TAGS_LOOKUP_DELAY=0
  export PATH="$MOCK:$PATH"
  cat > "$MOCK/gh" <<'MOCK_GH'
#!/usr/bin/env bash
case "$*" in
  *"repos/owner/repo/pulls/17/files"*) printf '%s\n' "$GH_FILES_JSON" ;;
  *"repos/owner/repo/commits/"*"/pulls"*)
    echo call >> "$GH_COMMIT_CALLS"
    if [[ -n "${GH_COMMIT_PULLS_LATE:-}" && $(wc -l < "$GH_COMMIT_CALLS") -lt 2 ]]; then
      printf '[]\n'
    else
      printf '%s\n' "${GH_COMMIT_PULLS_JSON:-[]}"
    fi ;;
  *"repos/owner/repo/pulls/17"*)
    [[ -z "${GH_PR_FAIL:-}" ]] || exit 1
    printf '%s\n' "$GH_PR_JSON" ;;
  *) exit 2 ;;
esac
MOCK_GH
  chmod +x "$MOCK/gh"
  write_event '[]'
}

teardown() {
  rm -rf "$TEST_ROOT"
}

write_event() {
  jq -n --arg sha "$MERGE_SHA" --argjson labels "$1" \
    '{pull_request:{number:17,merged:true,merge_commit_sha:$sha,labels:$labels}}' > "$GITHUB_EVENT_PATH"
}

@test "moves the highest existing major tag to the merge commit" {
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Advanced example-action/v4 from $OLD_SHA to $MERGE_SHA."* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$MERGE_SHA" ]
  [ "$(git --git-dir="$REMOTE" rev-parse refs/tags/example-action/v2)" = "$OLD_SHA" ]
}

@test "major-release label fails without moving any tag" {
  write_event '[{"name":"major-release"}]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares major-release"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse refs/tags/example-action/v4)" = "$OLD_V4_OID" ]
}

@test "action with no published major tag is skipped" {
  git -C "$WORK" tag -d example-action/v2 example-action/v4 >/dev/null
  git -C "$WORK" push origin :refs/tags/example-action/v2 :refs/tags/example-action/v4 >/dev/null 2>&1
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No existing major tag for example-action; skipping."* ]]
}

@test "refuses to move a tag that is ahead of the merged commit" {
  printf 'future\n' > "$WORK/future.txt"
  git -C "$WORK" add future.txt
  git -C "$WORK" commit -m future >/dev/null
  FUTURE_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" push origin main >/dev/null 2>&1
  export FUTURE_SHA REMOTE
  git -C "$WORK" tag -f example-action/v4 "$FUTURE_SHA" >/dev/null
  git -C "$WORK" push --force origin refs/tags/example-action/v4 >/dev/null 2>&1

  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not an ancestor of merge commit"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse refs/tags/example-action/v4)" = "$FUTURE_SHA" ]
}

@test "binary action ambiguity prevents all tag updates" {
  export GH_FILES_JSON='[[{"filename":".github/actions/example-action/action.yml"},{"filename":".github/actions/linear-release-sync/src/main.go"}]]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"linear-release-sync is a binary action"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$OLD_SHA" ]
}

@test "malformed GitHub API response fails closed" {
  export GH_FILES_JSON='[[{}]]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed changed-file data"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$OLD_SHA" ]
}

@test "event file count mismatch fails closed" {
  jq '.pull_request.changed_files = 2' "$GITHUB_EVENT_PATH" > "$TEST_ROOT/event-updated.json"
  mv "$TEST_ROOT/event-updated.json" "$GITHUB_EVENT_PATH"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"event reports 2"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$OLD_SHA" ]
}

@test "atomic lease failure does not partially move other tags" {
  printf 'name: second\n# updated\n' > "$WORK/.github/actions/second-action/action.yml"
  git -C "$WORK" add .github/actions/second-action/action.yml
  git -C "$WORK" commit -m update-second >/dev/null
  FUTURE_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" push origin main >/dev/null 2>&1
  export GH_FILES_JSON='[[{"filename":".github/actions/example-action/action.yml"},{"filename":".github/actions/second-action/action.yml"}]]'

  mkdir -p "$REMOTE/hooks"
  git --git-dir="$REMOTE" config core.hooksPath hooks
  cat > "$REMOTE/hooks/pre-receive" <<'UPDATE_HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
  if [[ "$ref" == refs/tags/second-action/v1 ]]; then
    echo "simulated concurrent tag conflict" >&2
    exit 1
  fi
done
exit 0
UPDATE_HOOK
  chmod +x "$REMOTE/hooks/pre-receive"

  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"atomic push was rejected"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$OLD_SHA" ]
  [ "$(git --git-dir="$REMOTE" rev-parse refs/tags/second-action/v1)" = "$OLD_SHA" ]
}

write_push_event() {
  jq -n --arg sha "$MERGE_SHA" '{after:$sha}' > "$GITHUB_EVENT_PATH"
  export GH_COMMIT_PULLS_JSON
  GH_COMMIT_PULLS_JSON=$(jq -nc --arg sha "$MERGE_SHA" '[{number:16,merge_commit_sha:"other"},{number:17,merge_commit_sha:$sha}]')
  export GH_PR_JSON
  GH_PR_JSON=$(jq -nc --arg sha "$MERGE_SHA" --argjson labels "$1" '{number:17,merged:true,merge_commit_sha:$sha,changed_files:1,labels:$labels}')
}

@test "push event resolves the merged PR and moves its tag" {
  write_push_event '[]'
  export GITHUB_OUTPUT="$TEST_ROOT/output"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Advanced example-action/v4 from $OLD_SHA to $MERGE_SHA."* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$MERGE_SHA" ]
  grep -qx 'pr-number=17' "$GITHUB_OUTPUT"
}

@test "push event keeps the major-release gate" {
  write_push_event '[{"name":"major-release"}]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares major-release"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse refs/tags/example-action/v4)" = "$OLD_V4_OID" ]
}

@test "push with no merged PR fails without moving tags" {
  jq -n --arg sha "$MERGE_SHA" '{after:$sha}' > "$GITHUB_EVENT_PATH"
  export GH_COMMIT_PULLS_JSON='[]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No merged pull request found for $MERGE_SHA"* ]]
  [ "$(wc -l < "$GH_COMMIT_CALLS")" -eq 3 ]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$OLD_SHA" ]
}

@test "push retries when GitHub links the PR late" {
  write_push_event '[]'
  export GH_COMMIT_PULLS_LATE=1
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Advanced example-action/v4 from $OLD_SHA to $MERGE_SHA."* ]]
  [ "$(wc -l < "$GH_COMMIT_CALLS")" -eq 2 ]
}

@test "push uses the PR named in the commit subject when GitHub never links it" {
  write_push_event '[]'
  jq --arg msg $'feat: something (#17)\n\nbody' '.head_commit.message = $msg' "$GITHUB_EVENT_PATH" > "$TEST_ROOT/e.json"
  mv "$TEST_ROOT/e.json" "$GITHUB_EVENT_PATH"
  export GH_COMMIT_PULLS_JSON='[]'
  export GITHUB_OUTPUT="$TEST_ROOT/output"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Advanced example-action/v4 from $OLD_SHA to $MERGE_SHA."* ]]
  [ ! -e "$GH_COMMIT_CALLS" ]
  [ "$(grep -c 'pr-number=17' "$GITHUB_OUTPUT")" -eq 1 ]
}

@test "push ignores a named PR whose merge commit is a different commit" {
  write_push_event '[]'
  jq '.head_commit.message = "revert: something (#17)"' "$GITHUB_EVENT_PATH" > "$TEST_ROOT/e.json"
  mv "$TEST_ROOT/e.json" "$GITHUB_EVENT_PATH"
  GH_PR_JSON=$(jq -c '.merge_commit_sha = "other"' <<< "$GH_PR_JSON")
  export GH_COMMIT_PULLS_JSON='[]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No merged pull request found for $MERGE_SHA"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$OLD_SHA" ]
}

@test "push exports the PR number before a failed PR read" {
  write_push_event '[]'
  export GH_PR_FAIL=1
  export GITHUB_OUTPUT="$TEST_ROOT/output"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not read PR #17"* ]]
  grep -qx 'pr-number=17' "$GITHUB_OUTPUT"
}

@test "push falls back to the commit link when the subject names an unreadable PR" {
  write_push_event '[]'
  jq '.head_commit.message = "fix: something (#99)"' "$GITHUB_EVENT_PATH" > "$TEST_ROOT/e.json"
  mv "$TEST_ROOT/e.json" "$GITHUB_EVENT_PATH"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Advanced example-action/v4 from $OLD_SHA to $MERGE_SHA."* ]]
  [ "$(wc -l < "$GH_COMMIT_CALLS")" -eq 1 ]
}

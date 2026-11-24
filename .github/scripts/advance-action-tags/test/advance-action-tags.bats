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
  export GH_DISPATCHES="$TEST_ROOT/dispatches"
  export GH_RUN_LISTS="$TEST_ROOT/run-lists"
  export GITHUB_RUN_ID=99 GITHUB_RUN_ATTEMPT=1
  export ADVANCE_TAGS_WATCH_INTERVAL=0
  export PATH="$MOCK:$PATH"
  cat > "$MOCK/gh" <<'MOCK_GH'
#!/usr/bin/env bash
case "$*" in
  *"repos/owner/repo/pulls/17/files"*) printf '%s\n' "$GH_FILES_JSON" ;;
  *"repos/owner/repo/commits/"*"/pulls"*)
    echo call >> "$GH_COMMIT_CALLS"
    if [[ -n "${GH_COMMIT_PULLS_ERROR_ONCE:-}" && $(wc -l < "$GH_COMMIT_CALLS") -lt 2 ]]; then
      exit 1
    fi
    if [[ -n "${GH_COMMIT_PULLS_LATE:-}" && $(wc -l < "$GH_COMMIT_CALLS") -lt 2 ]]; then
      printf '[]\n'
    else
      printf '%s\n' "${GH_COMMIT_PULLS_JSON:-[]}"
    fi ;;
  *"repos/owner/repo/pulls/17"*)
    [[ -z "${GH_PR_FAIL:-}" ]] || exit 1
    printf '%s\n' "$GH_PR_JSON" ;;
  "workflow run "*)
    echo "$*" >> "$GH_DISPATCHES"
    [[ -z "${GH_DISPATCH_FAIL:-}" ]] || exit 1 ;;
  "run list "*)
    echo "$*" >> "$GH_RUN_LISTS"
    # Apply the script's own --jq filter to two runs, one from another
    # dispatch, so a wrong id or filter finds nothing.
    filter=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" != --jq ]] || filter=$2
      shift
    done
    runs='[{"databaseId":1111,"displayTitle":"Release linear-release-sync/v1 [98.1-linear-release-sync]"},{"databaseId":4242,"displayTitle":"Release linear-release-sync/v1 [99.1-linear-release-sync]"}]'
    [[ -z "${GH_RUN_MISSING:-}" ]] || runs='[{"databaseId":1111,"displayTitle":"Release linear-release-sync/v1 [98.1-linear-release-sync]"}]'
    jq -r "$filter" <<< "$runs" ;;
  "run watch 4242 "*)
    # A newer merge can move the tag while this build waits in its queue.
    [[ -z "${GH_WATCH_MOVES_TAG:-}" ]] || git --git-dir="$REMOTE" update-ref refs/tags/linear-release-sync/v1 "$GH_WATCH_MOVES_TAG"
    [[ -z "${GH_WATCH_SLEEP:-}" ]] || sleep "$GH_WATCH_SLEEP"
    exit "${GH_WATCH_STATUS:-0}" ;;
  "run view 4242 "*) echo "${GH_RUN_CONCLUSION-failure}" ;;
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
  export GITHUB_OUTPUT="$TEST_ROOT/output"
  write_event '[{"name":"major-release"}]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares major-release"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse refs/tags/example-action/v4)" = "$OLD_V4_OID" ]
  # A tag failure keeps the tag-recovery comment.
  run grep -q 'failure-reason=' "$GITHUB_OUTPUT"
  [ "$status" -ne 0 ]
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

@test "push retries the commit link after a GitHub error" {
  write_push_event '[]'
  export GH_COMMIT_PULLS_ERROR_ONCE=1
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Advanced example-action/v4 from $OLD_SHA to $MERGE_SHA."* ]]
  [ "$(wc -l < "$GH_COMMIT_CALLS")" -eq 2 ]
}

@test "push fails after the commit link errors on every try" {
  write_push_event '[]'
  cat > "$MOCK/gh" <<'MOCK_GH'
#!/usr/bin/env bash
echo call >> "$GH_COMMIT_CALLS"
exit 1
MOCK_GH
  chmod +x "$MOCK/gh"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not list pull requests for $MERGE_SHA"* ]]
  [ "$(git --git-dir="$REMOTE" rev-parse 'refs/tags/example-action/v4^{commit}')" = "$OLD_SHA" ]
}

# Writes each path=content pair, commits, pushes, and makes that commit the
# merged PR whose changed files are the given paths.
merge_files() {
  local files=() pair path
  for pair in "$@"; do
    path=${pair%%=*}
    mkdir -p "$WORK/$(dirname "$path")"
    printf '%s\n' "${pair#*=}" >> "$WORK/$path"
    git -C "$WORK" add "$path"
    files+=("$path")
  done
  git -C "$WORK" commit -m merge >/dev/null
  MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" push origin main >/dev/null 2>&1
  GH_FILES_JSON=$(printf '%s\n' "${files[@]}" | jq -Rnc '[[inputs | {filename: .}]]')
  export GH_FILES_JSON
  write_event '[]'
}

tag_commit() {
  git --git-dir="$REMOTE" rev-parse "refs/tags/$1^{commit}"
}

@test "a changed library advances the tag of the action that loads it" {
  merge_files ".github/actions/second-action/run.py=import_path('../shared-lib')"
  merge_files ".github/actions/shared-lib/rules.py=FIX = 1"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"shared-lib is loaded by: second-action"* ]]
  [ "$(tag_commit second-action/v1)" = "$MERGE_SHA" ]
  [ "$(tag_commit example-action/v4)" = "$OLD_SHA" ]
}

@test "a changed library advances every action that loads it in one push" {
  merge_files ".github/actions/second-action/run.sh=source ../shared-lib/lib.sh" \
    ".github/actions/example-action/src/main.py=sys.path.append('shared-lib')"
  merge_files ".github/actions/shared-lib/lib.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit second-action/v1)" = "$MERGE_SHA" ]
  [ "$(tag_commit example-action/v4)" = "$MERGE_SHA" ]
}

@test "a library changed with an action that loads it advances that action once" {
  merge_files ".github/actions/second-action/run.sh=source ../shared-lib/lib.sh"
  merge_files ".github/actions/shared-lib/lib.sh=fix" ".github/actions/second-action/run.sh=more"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Advanced second-action/v1' <<< "$output")" -eq 1 ]
  [ "$(tag_commit second-action/v1)" = "$MERGE_SHA" ]
}

@test "a library loaded through another library advances the action at the end" {
  merge_files ".github/actions/second-action/run.sh=source ../outer-lib/lib.sh" \
    ".github/actions/outer-lib/lib.sh=source ../inner-lib/lib.sh"
  merge_files ".github/actions/inner-lib/lib.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit second-action/v1)" = "$MERGE_SHA" ]
  [ "$(tag_commit example-action/v4)" = "$OLD_SHA" ]
}

@test "a library only a README mentions has no user and fails closed" {
  merge_files ".github/actions/second-action/README.md=See shared-lib."
  merge_files ".github/actions/shared-lib/lib.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared-lib has no action.yml and no action uses it"* ]]
  [ "$(tag_commit second-action/v1)" = "$OLD_SHA" ]
}

@test "a removed action nothing references still fails closed" {
  export GH_FILES_JSON='[[{"filename":".github/actions/gone-action/action.yml"}]]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gone-action is missing action.yml at merge commit"* ]]
  [ "$(tag_commit example-action/v4)" = "$OLD_SHA" ]
}

@test "an action that loads a library but has no major tag is skipped" {
  merge_files ".github/actions/third-action/action.yml=name: third" \
    ".github/actions/third-action/run.sh=source ../shared-lib/lib.sh"
  merge_files ".github/actions/shared-lib/lib.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No existing major tag for third-action; skipping."* ]]
}

# A binary action's callers download its binary from the release, so moving
# the tag must also start the release build. A tag pushed with GITHUB_TOKEN
# starts no workflow, so the script dispatches it.
publish_binary_tag() {
  git -C "$WORK" tag linear-release-sync/v1 "$OLD_SHA"
  git -C "$WORK" push origin refs/tags/linear-release-sync/v1 >/dev/null 2>&1
}

dispatched_release() {
  grep -qxF "workflow run release-linear-release-sync.yaml --repo owner/repo --ref linear-release-sync/v1 -f tag=linear-release-sync/v1 -f dispatch-id=99.1-linear-release-sync" "$GH_DISPATCHES"
}

@test "a binary action advances its tag and dispatches its release build" {
  publish_binary_tag
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs" \
    ".github/actions/linear-release-sync/src/main.go=package main"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit linear-release-sync/v1)" = "$MERGE_SHA" ]
  dispatched_release
  [ "$(wc -l < "$GH_DISPATCHES")" -eq 1 ]
  [[ "$output" == *"Started release-linear-release-sync.yaml for linear-release-sync/v1"* ]]
  # The run is found by the dispatch id in its title, not by time.
  grep -qF '99.1-linear-release-sync' "$GH_RUN_LISTS"
  [[ "$output" == *"Release build 4242 for linear-release-sync/v1 succeeded"* ]]
}

@test "a re-run after the tag already moved still rebuilds the release binary" {
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs"
  # The first attempt moved the tag, then its build failed.
  git -C "$WORK" tag linear-release-sync/v1 "$MERGE_SHA"
  git -C "$WORK" push origin refs/tags/linear-release-sync/v1 >/dev/null 2>&1
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Advanced linear-release-sync/v1"* ]]
  dispatched_release
  [[ "$output" == *"Release build 4242 for linear-release-sync/v1 succeeded"* ]]
}

@test "a run that moves no tag says so" {
  git -C "$WORK" tag -f example-action/v4 "$MERGE_SHA" >/dev/null
  git -C "$WORK" push --force origin refs/tags/example-action/v4 >/dev/null 2>&1
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No existing action tags need advancing for PR #17."* ]]
}

@test "a release build that fails after the dispatch fails the run" {
  publish_binary_tag
  export GITHUB_OUTPUT="$TEST_ROOT/output"
  export GH_WATCH_STATUS=1 GH_RUN_CONCLUSION=failure
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Release build 4242 for linear-release-sync/v1 ended failure"* ]]
  [[ "$output" == *"gh workflow run release-linear-release-sync.yaml"* ]]
  # The PR comment points at the release build, not at the tags.
  grep -qx 'failure-reason=release-build' "$GITHUB_OUTPUT"
}

@test "a release build still running at the watch deadline fails the run" {
  # The deadline needs coreutils timeout, as on the CI runner; stock macOS has none.
  command -v timeout >/dev/null || skip "needs coreutils timeout"
  publish_binary_tag
  export GH_WATCH_SLEEP=5 ADVANCE_TAGS_WATCH_TIMEOUT=1 GH_RUN_CONCLUSION=""
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Release build 4242 for linear-release-sync/v1 did not finish"* ]]
}

@test "a release build that never appears fails the run" {
  publish_binary_tag
  export GH_RUN_MISSING=1
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not find the release-linear-release-sync.yaml run"* ]]
}

@test "a release build cancelled for a newer build of a moved tag is not a failure" {
  publish_binary_tag
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs"
  first_merge=$MERGE_SHA
  merge_files ".github/actions/linear-release-sync/src/main.go=package main"
  export REMOTE GH_WATCH_MOVES_TAG=$MERGE_SHA GH_WATCH_STATUS=1 GH_RUN_CONCLUSION=cancelled
  MERGE_SHA=$first_merge write_event '[]'
  export GH_FILES_JSON='[[{"filename":".github/actions/linear-release-sync/action.yml"}]]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"was cancelled for a newer build"* ]]
}

@test "a cancelled release build of the current tag fails the run" {
  publish_binary_tag
  export GH_WATCH_STATUS=1 GH_RUN_CONCLUSION=cancelled
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ended cancelled"* ]]
}

@test "a binary action changed with another action advances both tags" {
  publish_binary_tag
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs" \
    ".github/actions/example-action/action.yml=# fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit linear-release-sync/v1)" = "$MERGE_SHA" ]
  [ "$(tag_commit example-action/v4)" = "$MERGE_SHA" ]
  dispatched_release
  [ "$(wc -l < "$GH_DISPATCHES")" -eq 1 ]
}

@test "a binary action that loads a changed library advances and dispatches its release build" {
  publish_binary_tag
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs" \
    ".github/actions/linear-release-sync/run.sh=source ../shared-lib/lib.sh" \
    ".github/actions/second-action/run.sh=source ../shared-lib/lib.sh"
  merge_files ".github/actions/shared-lib/lib.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit linear-release-sync/v1)" = "$MERGE_SHA" ]
  [ "$(tag_commit second-action/v1)" = "$MERGE_SHA" ]
  dispatched_release
}

@test "a failed release dispatch fails the run and names the manual rebuild" {
  publish_binary_tag
  export GITHUB_OUTPUT="$TEST_ROOT/output"
  export GH_DISPATCH_FAIL=1
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [ "$(tag_commit linear-release-sync/v1)" = "$MERGE_SHA" ]
  [[ "$output" == *"gh workflow run release-linear-release-sync.yaml"* ]]
  grep -qx 'failure-reason=release-build' "$GITHUB_OUTPUT"
}

@test "a binary action with no major tag is skipped without a release build" {
  merge_files ".github/actions/linear-release-sync/action.yml=name: lrs"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No existing major tag for linear-release-sync; skipping."* ]]
  [ ! -e "$GH_DISPATCHES" ]
}

@test "an ordinary action starts no release build" {
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ ! -e "$GH_DISPATCHES" ]
}

@test "a removed action that another action mentions still fails closed" {
  merge_files ".github/actions/doomed-action/action.yml=name: doomed" \
    ".github/actions/second-action/action.yml=# works like doomed-action"
  git -C "$WORK" rm -rq .github/actions/doomed-action
  git -C "$WORK" commit -m remove >/dev/null
  MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" push origin main >/dev/null 2>&1
  export GH_FILES_JSON='[[{"filename":".github/actions/doomed-action/action.yml"}]]'
  write_event '[]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"doomed-action is missing action.yml at merge commit"* ]]
  [ "$(tag_commit second-action/v1)" = "$OLD_SHA" ]
}

@test "a renamed action fails closed instead of following its old name" {
  merge_files ".github/actions/old-name/action.yml=name: old" \
    ".github/actions/second-action/run.sh=source ../old-name/lib.sh"
  git -C "$WORK" mv .github/actions/old-name .github/actions/new-name
  git -C "$WORK" commit -m rename >/dev/null
  MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" push origin main >/dev/null 2>&1
  export GH_FILES_JSON='[[{"filename":".github/actions/new-name/action.yml","previous_filename":".github/actions/old-name/action.yml"}]]'
  write_event '[]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"old-name is missing action.yml at merge commit"* ]]
  [ "$(tag_commit second-action/v1)" = "$OLD_SHA" ]
}

@test "an action.yml removed from a directory that keeps other files fails closed" {
  merge_files ".github/actions/second-action/lib.sh=x" \
    ".github/actions/example-action/run.sh=source ../second-action/lib.sh"
  git -C "$WORK" rm -q .github/actions/second-action/action.yml
  git -C "$WORK" commit -m drop >/dev/null
  MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" push origin main >/dev/null 2>&1
  export GH_FILES_JSON='[[{"filename":".github/actions/second-action/action.yml"}]]'
  write_event '[]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"second-action is missing action.yml at merge commit"* ]]
  [ "$(tag_commit example-action/v4)" = "$OLD_SHA" ]
}

@test "a library named only in a comment has no user and fails closed" {
  merge_files ".github/actions/second-action/run.sh=# see shared-lib for details"
  merge_files ".github/actions/shared-lib/lib.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared-lib has no action.yml and no action uses it"* ]]
  [ "$(tag_commit second-action/v1)" = "$OLD_SHA" ]
}

@test "shared code inside an action advances the actions that load it too" {
  merge_files ".github/actions/second-action/run.sh=bash \${{ github.action_path }}/../example-action/src/install.sh"
  merge_files ".github/actions/example-action/src/install.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit example-action/v4)" = "$MERGE_SHA" ]
  [ "$(tag_commit second-action/v1)" = "$MERGE_SHA" ]
}

@test "an action change advances only that action when nothing loads it" {
  merge_files ".github/actions/second-action/run.sh=# example-action does the same"
  merge_files ".github/actions/example-action/src/install.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit example-action/v4)" = "$MERGE_SHA" ]
  [ "$(tag_commit second-action/v1)" = "$OLD_SHA" ]
}

@test "a library only an action's tests load has no user and fails closed" {
  merge_files ".github/actions/second-action/test/run.bats=load ../shared-lib/lib.sh"
  merge_files ".github/actions/shared-lib/lib.sh=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared-lib has no action.yml and no action uses it"* ]]
  [ "$(tag_commit second-action/v1)" = "$OLD_SHA" ]
}

@test "an action.yml removed in an earlier commit of a rebase merge still fails closed" {
  merge_files ".github/actions/second-action/lib.sh=x" \
    ".github/actions/example-action/run.sh=source ../second-action/lib.sh"
  git -C "$WORK" rm -q .github/actions/second-action/action.yml
  git -C "$WORK" commit -m drop >/dev/null
  printf 'more\n' >> "$WORK/.github/actions/second-action/lib.sh"
  git -C "$WORK" commit -qam edit
  MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
  git -C "$WORK" push origin main >/dev/null 2>&1
  export GH_FILES_JSON='[[{"filename":".github/actions/second-action/action.yml"},{"filename":".github/actions/second-action/lib.sh"}]]'
  write_event '[]'
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"second-action is missing action.yml at merge commit"* ]]
  [ "$(tag_commit example-action/v4)" = "$OLD_SHA" ]
}

@test "a library loaded by a path at the end of a line or inside a longer path is found" {
  merge_files ".github/actions/second-action/action.yml=      PYTHONPATH: \${{ github.action_path }}/../shared-lib" \
    ".github/actions/example-action/src/main.py=open(f\"{root}/shared-lib/rules.py\")"
  merge_files ".github/actions/shared-lib/rules.py=fix"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit second-action/v1)" = "$MERGE_SHA" ]
  [ "$(tag_commit example-action/v4)" = "$MERGE_SHA" ]
}

@test "a library new in the merged change advances the actions that load it" {
  merge_files ".github/actions/shared-lib/rules.py=new" \
    ".github/actions/second-action/run.py=import_path('../shared-lib')"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(tag_commit second-action/v1)" = "$MERGE_SHA" ]
}

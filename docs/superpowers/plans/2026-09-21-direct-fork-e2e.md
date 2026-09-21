# Direct Fork E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open separate draft PRs that demonstrate direct, maintainer-authorized `/test-e2e` execution for fork pull requests without the label handoff.

**Architecture:** The shared action opts fork requests into an exact permission check and returns `is-fork`. vcluster-pro keeps `workflow_dispatch` for same-repository pull requests and calls its existing E2E workflows directly as reusable workflows for fork requests, with exact-SHA checkout and `cache-mode: read`.

**Tech Stack:** GitHub Actions YAML, Bash, Bats, actionlint, ShellCheck, zizmor

**Spec:** `docs/superpowers/specs/2026-09-21-direct-fork-e2e-design.md`

## Global Constraints

- Do not modify or force-push the existing label-handoff draft branches or PRs.
- Fork support stays opt-in and requires `write`, `maintain`, or `admin` permission.
- The privileged preparation job never checks out pull request code or receives cloud credentials.
- Fork suite jobs check out the captured head SHA with `persist-credentials: false`.
- Fork suite jobs set `cache-mode: read` and pass only the existing secrets needed by that suite.
- Same-repository command dispatch remains unchanged.

---

### Task 1: Add minimal fork authorization to the shared action

**Files:**
- Modify: `.github/actions/comment-triggered-check/test/start.bats`
- Modify: `.github/actions/comment-triggered-check/test/gh_mock.bash`
- Modify: `.github/actions/comment-triggered-check/test/action-wiring.bats`
- Modify: `.github/actions/comment-triggered-check/src/lib.sh`
- Modify: `.github/actions/comment-triggered-check/src/start.sh`
- Modify: `.github/actions/comment-triggered-check/action.yml`
- Modify: `.github/actions/comment-triggered-check/README.md`

**Interfaces:**
- Consumes: `allow-forks: true`, the comment author, and the resolved pull request.
- Produces: `is-fork=true|false`; `should-run=true` for an authorized fork; `permission-unreadable` or `insufficient-permission` on failure.

- [ ] **Step 1: Write failing Bats tests**

Add mock support for `repos/<repo>/collaborators/<actor>/permission` and tests equivalent to:

```bash
@test "an allowed fork runs for a write-level commenter" {
  export INPUT_ALLOW_FORKS=true
  export GH_MOCK_PR_JSON='{"head":{"sha":"fork123","ref":"feature","repo":{"full_name":"someone/demo"}},"base":{"ref":"main"},"state":"open"}'
  export GH_MOCK_PERMISSION_JSON='{"permission":"write"}'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(kv should-run)" = "true" ]
  [ "$(kv is-fork)" = "true" ]
}

@test "an allowed fork refuses a read-level commenter" {
  export INPUT_ALLOW_FORKS=true
  export GH_MOCK_PR_JSON='{"head":{"sha":"fork123","ref":"feature","repo":{"full_name":"someone/demo"}},"base":{"ref":"main"},"state":"open"}'
  export GH_MOCK_PERMISSION_JSON='{"permission":"read"}'
  run "$SCRIPT"
  [ "$(kv should-run)" = "false" ]
  [ "$(kv reason)" = "insufficient-permission" ]
}
```

Also assert that the existing default fork refusal performs no permission lookup, a failed or malformed permission response returns `permission-unreadable`, and same-repository requests return `is-fork=false`.

- [ ] **Step 2: Run the focused suite and verify RED**

Run: `bats .github/actions/comment-triggered-check/test/start.bats .github/actions/comment-triggered-check/test/action-wiring.bats`

Expected: the new tests fail because `allow-forks`, `is-fork`, and the permission endpoint are not wired.

- [ ] **Step 3: Implement the minimal contract**

Add:

```bash
has_write_permission() {
  case "${1-}" in
    write|maintain|admin) return 0 ;;
    *) return 1 ;;
  esac
}
```

In `start.sh`, leave the current `reason=fork` path as the default. When `INPUT_ALLOW_FORKS=true`, query `repos/${repo}/collaborators/${comment_author}/permission`, require a readable string, and accept only `has_write_permission`. Emit `is-fork` on every exit path.

In `action.yml`, add the `allow-forks` input and `is-fork` output, wire `INPUT_ALLOW_FORKS`, and list `permission-unreadable` in the reason contract. Do not add queue, resolver, label, bot, or token inputs.

- [ ] **Step 4: Run shared-action verification**

Run:

```bash
make test-comment-triggered-check
shellcheck -x .github/actions/comment-triggered-check/src/*.sh
make check-docs
make lint
```

Expected: all Bats tests pass; generated docs are current; ShellCheck and repository lint are clean apart from documented existing findings.

- [ ] **Step 5: Commit the shared action**

```bash
git add .github/actions/comment-triggered-check README.md docs/superpowers
git commit -m "feat(e2e): authorize direct fork commands"
```

### Task 2: Add direct fork routing to vcluster-pro

**Files:**
- Modify: `.github/tests/test-e2e-command-focus.sh`
- Modify: `.github/workflows/e2e-command.yaml`
- Modify: `.github/workflows/e2e.yaml`
- Modify: `.github/workflows/e2e-oss-ginkgo.yaml`

**Interfaces:**
- Consumes: `is-fork`, `head-sha`, `base-ref`, filter, focus, target, concurrency key, and check-run IDs from Task 1.
- Produces: same-repository dispatch jobs plus fork-only reusable Pro and OSS jobs that complete the existing custom checks.

- [ ] **Step 1: Write failing workflow contract assertions**

Extend `.github/tests/test-e2e-command-focus.sh` to require:

```bash
assert_count "$COMMAND" 'allow-forks: true' 2 \
  "both target parsers explicitly allow authorized forks"
assert_contains "$COMMAND" 'is-fork: ${{ steps.pro.outputs.target == '\''oss'\'' && steps.oss.outputs.is-fork || steps.pro.outputs.is-fork }}' \
  "prepare exports fork identity"
assert_count "$COMMAND" 'cache-mode: read' 2 \
  "fork suites cannot write Actions caches"
assert_contains "$PRO" 'workflow_call:' \
  "the pro suite supports a trusted reusable call"
assert_contains "$OSS" 'workflow_call:' \
  "the oss suite supports a trusted reusable call"
assert_count "$PRO" 'persist-credentials: false' 5 \
  "every pro checkout drops repository credentials"
```

Also assert that fork jobs pass the captured SHA and check-run IDs, target gates select only the requested tree, and no `queue-fork`, `resolve-fork`, bot token, request label, or fork bridge workflow exists.

- [ ] **Step 2: Run the contract test and verify RED**

Run: `bash .github/tests/test-e2e-command-focus.sh`

Expected: assertions fail because no fork output, reusable call, or read-only cache mode exists.

- [ ] **Step 3: Make both suite workflows reusable**

Add `workflow_call` contracts matching the existing dispatch inputs, including `head-sha`, `check-run-id`, `concurrency-key`, `compose-with-pr`, filter, and focus. Add a boolean `command-run` input where behavior must distinguish a direct command from the pull request gate.

For every checkout use:

```yaml
with:
  ref: ${{ inputs.head-sha || (github.event_name == 'pull_request' && github.event.pull_request.head.sha) || '' }}
  persist-credentials: false
```

Use `git rev-parse HEAD` in preflight to verify `inputs.head-sha`, and treat `inputs.command-run` like `check-run-id != ''` for timeouts, report attribution, neutral empty selection, and check completion.

- [ ] **Step 4: Route fork jobs directly**

In preparation, set `allow-forks: true` on both shared-action calls and export `is-fork`. Keep the contract probe and `workflow_dispatch` jobs only for `is-fork != 'true'`.

Add two job-level reusable calls shaped as:

```yaml
fork-pro:
  needs: prepare
  if: ${{ needs.prepare.outputs.should-run == 'true' && needs.prepare.outputs.is-fork == 'true' && needs.prepare.outputs.target != 'oss' }}
  uses: ./.github/workflows/e2e.yaml
  cache-mode: read
  with:
    head-sha: ${{ needs.prepare.outputs.head-sha }}
    check-run-id: ${{ needs.prepare.outputs.pro-check-run-id }}
    command-run: true
    compose-with-pr: false
```

Create the OSS equivalent gated by `target != 'pro'`. Declare least privilege and explicitly pass only each suite's current E2E secrets.

- [ ] **Step 5: Run caller verification**

Run:

```bash
bash .github/tests/test-e2e-command-focus.sh
actionlint .github/workflows/e2e-command.yaml .github/workflows/e2e.yaml .github/workflows/e2e-oss-ginkgo.yaml
zizmor .github/workflows/e2e-command.yaml .github/workflows/e2e.yaml .github/workflows/e2e-oss-ginkgo.yaml
```

Expected: contract test and actionlint pass; zizmor has no new high-confidence finding.

- [ ] **Step 6: Commit the caller**

```bash
git add .github/tests/test-e2e-command-focus.sh .github/workflows/e2e-command.yaml .github/workflows/e2e.yaml .github/workflows/e2e-oss-ginkgo.yaml
git commit -m "feat(e2e): run authorized fork commands directly"
```

### Task 3: Open separate draft PRs

**Files:**
- Read: repository pull request templates
- No source changes

**Interfaces:**
- Consumes: verified commits from Tasks 1 and 2.
- Produces: two new draft PR URLs; existing PRs remain unchanged.

- [ ] **Step 1: Push both alternative branches**

Run `git push -u origin devops-1541/direct-fork-e2e` in each isolated worktree.

- [ ] **Step 2: Open the shared-action draft**

Use the repository template when present. Title: `feat(e2e): authorize direct fork commands`. Explain that this is the minimal alternative to the label-handoff draft, list local verification, and add `Related to DEVOPS-1541` so the comparison PR does not independently close the issue.

- [ ] **Step 3: Open the vcluster-pro draft**

Preserve every template section and directive. Title: `feat(e2e): run authorized fork commands directly`. Explain the same-repository/fork split, exact-SHA checkout, explicit secrets, and read-only cache boundary. Add `Related to DEVOPS-1541`.

- [ ] **Step 4: Verify both drafts**

Run `gh pr view` for each PR and confirm draft state, base branch, title, body, branch, and unchanged status of the existing label-handoff PRs.

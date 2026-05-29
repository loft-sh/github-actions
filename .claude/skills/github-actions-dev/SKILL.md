---
name: github-actions-dev
description: Develop and test reusable GitHub Actions in the loft-sh/github-actions repository. Use when adding new actions, modifying existing ones, running tests, or releasing action versions. Triggers on work in ~/loft/github-actions or github-actions worktrees.
---

# github-actions Repository Development

Repo: `loft-sh/github-actions` — reusable GitHub Actions for loft-sh org.

## Repo structure

```
.github/
  actions/           # reusable actions (each in its own directory)
    semver-validation/     # node24, jest tests
    linear-pr-commenter/   # composite, go tests
    release-notification/  # composite, yaml-only (no testable logic)
    ci-notify-nightly-tests/  # composite, yaml-only
  workflows/         # CI and reusable workflows
Makefile             # local test harness
```

## Running tests

```bash
make test                       # all action tests
make test-semver-validation     # jest tests only
make test-linear-pr-commenter   # go tests only
make lint                       # actionlint + zizmor
```

## Adding a new action

1. Create `.github/actions/<action-name>/action.yml`
2. Add tests based on action type:
   - Node.js: `test/index.test.js` with Jest (see semver-validation pattern)
   - Go: `*_test.go` files (see linear-pr-commenter pattern)
   - Composite YAML-only: no unit tests, rely on actionlint
3. Add Makefile target: `test-<action-name>`
4. Add CI workflow: `.github/workflows/test-<action-name>.yaml` with path filter
5. Add README section under "Available Actions"

## Action pinning (non-negotiable)

All third-party actions use full SHA pins with version comment:

```yaml
# CORRECT
- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

# WRONG - never use tag references
- uses: actions/checkout@v4
```

Standard pins used across the repo:
- `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd` (v6.0.2)
- `actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020` (v4.4.0)
- `actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff` (v5.6.0)

Always add `persist-credentials: false` to checkout steps.

## Versioning and releasing

Each action gets its own tag (not repo-wide):

```bash
git tag -f <action-name>/v1
git push origin <action-name>/v1 --force
```

Exception: `release-notification` uses legacy repo-wide `v1` tag.

Referenced as:
```yaml
uses: loft-sh/github-actions/.github/actions/<action-name>@<action-name>/v1
```

## CI workflow pattern for tests

```yaml
name: Test <action-name>
on:
  push:
    branches: [main]
    paths: ['.github/actions/<action-name>/**']
  pull_request:
    paths: ['.github/actions/<action-name>/**']
jobs:
  test:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      # setup step + test command
```

## Gotchas: job-level `if` conditions

### success() transitive skip propagation

`success()` (the implicit default in `needs`) evaluates the ENTIRE transitive `needs` chain. If any ancestor job is skipped, ALL descendants skip too — even if the immediate parent succeeded.

Fix pattern: move skip-causing conditions from job-level `if` to step-level `if`. The job runs as a no-op (success) instead of being skipped, so downstream jobs proceed normally.

```yaml
# BAD: job skips on alpha tags, causing ALL downstream to skip
check_version:
  if: github.repository_owner == 'loft-sh' && !contains(github.event.release.tag_name, '-')

# GOOD: job always runs, steps skip on alpha tags
check_version:
  if: github.repository_owner == 'loft-sh'
  steps:
    - uses: actions/checkout@v6
      if: ${{ !contains(github.event.release.tag_name, '-') }}
    - name: Validate version
      if: ${{ !contains(github.event.release.tag_name, '-') }}
```

Reference: loft-enterprise#6265, vcluster#3636 (fix for vcluster#3593).

### Surgical condition removal

When fixing a compound `if` on a job, preserve all guards unrelated to the bug. Don't strip the whole condition — remove only the problematic part.

```yaml
# Original (buggy compound condition):
  if: github.repository_owner == 'loft-sh' && !contains(tag, '-')

# WRONG fix (removes ALL guards):
  if: always()

# CORRECT fix (preserves fork guard, moves only alpha condition to steps):
  if: github.repository_owner == 'loft-sh'
```

### Backport label matching

When creating a fix PR for a bug introduced by another PR, the fix must carry the same backport labels as the buggy PR — no more, no less. The fix only needs to reach branches where the bug was backported.

## Common mistakes

- Creating actions outside `.github/actions/` — all actions live there
- Forgetting path filter on test workflows — tests must be scoped
- Using `npm test` instead of `npx jest --ci` in Makefile — npm test may have different config
- Missing `permissions: contents: read` on CI jobs — principle of least privilege
- Forgetting to update README when adding new actions

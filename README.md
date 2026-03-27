# github-actions

Reusable GitHub Actions

See [Pipeline Conventions](docs/CONVENTIONS.md) for constraints on how actions
are written, tested, and structured.

## Available Actions

### Semver Validation Action

Validates whether a given version string follows semantic versioning (semver) format.

**Location:** `.github/actions/semver-validation`

**Usage:**

```yaml
- name: Validate version
  id: semver
  uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v1
  with:
    version: '1.2.3'

- name: Check if valid
  run: echo "Valid: ${{ steps.semver.outputs.is_valid }}"
```

**Inputs:**

- `version` (required): Version string to validate

**Outputs:**

- `is_valid`: Whether the version is valid semver (`true`/`false`)
- `parsed_version`: JSON object with parsed version components
- `error_message`: Error message if validation fails

See [semver-validation README](./.github/actions/semver-validation/README.md) for detailed documentation.

## Available Reusable Workflows

### Validate Renovate Config

Validates Renovate configuration files when they change in a pull request.

**Location:** `.github/workflows/validate-renovate.yaml`

**Usage:**

```yaml
name: Validate Renovate Config

on:
  pull_request:

jobs:
  validate-renovate:
    uses: loft-sh/github-actions/.github/workflows/validate-renovate.yaml@main
```

Detected config files: `renovate.json`, `renovate.json5`, `.renovaterc`, `.renovaterc.json`, `.github/renovate.json`, `.github/renovate.json5`.

### Actionlint

Lints GitHub Actions workflow files using actionlint with reviewdog integration.

**Location:** `.github/workflows/actionlint.yaml`

**Usage:**

```yaml
name: Actionlint

on:
  pull_request:

jobs:
  actionlint:
    uses: loft-sh/github-actions/.github/workflows/actionlint.yaml@main
```

**Inputs:**

- `reporter` (optional, default: `github-pr-review`): reviewdog reporter type

## Testing

Run all action tests locally:

```bash
make test
```

Run tests for a specific action:

```bash
make test-semver-validation
make test-linear-pr-commenter
```

Run linters (actionlint + zizmor):

```bash
make lint
```

See all available targets:

```bash
make help
```

### CI integration

Each testable action has a dedicated workflow that runs its tests on PRs when
the action's files change:

- `test-semver-validation.yaml` - triggers on `.github/actions/semver-validation/**`
- `test-linear-pr-commenter.yaml` - triggers on `.github/actions/linear-pr-commenter/**`

Each reusable workflow (`workflow_call`) also has a smoke/integration test
workflow that triggers on PRs when the workflow file changes:

- `test-validate-renovate.yaml` - calls `validate-renovate.yaml` with local ref
- `test-detect-changes.yaml` - calls `detect-changes.yaml` and asserts outputs (true/false)
- `test-actionlint-workflow.yaml` - calls `actionlint.yaml` with `github-pr-check` reporter
- `test-backport-parse.yaml` - calls `backport.yaml` and verifies it doesn't fail (expects skipped)
- `test-clean-github-cache-parse.yaml` - calls `clean-github-cache.yaml` as smoke test
- `test-cleanup-backport-branches.yaml` - calls `cleanup-backport-branches.yaml` with `dry-run: true`

Post-merge, `dispatch-integration-tests.yaml` triggers full E2E tests in
[vClusterLabs-Experiments/github-actions-test](https://github.com/vClusterLabs-Experiments/github-actions-test).

### Writing tests for new actions

1. Node.js actions - add a `test/` directory with Jest tests. See
   `semver-validation/test/index.test.js` for the pattern: spawn the action's
   `index.js` with `INPUT_*` env vars and a temp `GITHUB_OUTPUT` file, then
   assert on the parsed outputs.

2. Go actions - add `*_test.go` files next to the source. See
   `linear-pr-commenter/src/main_test.go`. Use standard `go test`.

3. Composite actions (YAML-only like `release-notification`) - these
   delegate to third-party actions and have no local business logic to unit
   test. Validate their YAML structure through actionlint instead.

4. Add a Makefile target for the new action following the existing pattern.

5. Add a CI workflow at `.github/workflows/test-<action-name>.yaml` with a
   `paths` filter scoped to the action's directory.

## Versioning Actions

### Release-notification Action

The existing release-notification action uses a repository-wide tag:

```bash
git tag -f v1
git push origin v1 --force
```

Referenced as:

```yaml
uses: loft-sh/github-actions/release-notification@v1
```

### New Actions

For all new actions, we use action-specific tags for independent versioning:

```bash
# For the ci-notify-nightly-tests action
git tag -f ci-notify-nightly-tests/v1
git push origin ci-notify-nightly-tests/v1 --force

# For the semver-validation action
git tag -f semver-validation/v1
git push origin semver-validation/v1 --force

# For other actions, follow the same pattern
git tag -f action-name/v1
git push origin action-name/v1 --force
```

### Referencing Actions in Workflows

```yaml
# Reference actions using their specific tag
uses: loft-sh/github-actions/.github/actions/ci-notify-nightly-tests@ci-notify-nightly-tests/v1
uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v1
```


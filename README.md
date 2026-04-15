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

### Linear Release Sync Action

Syncs Linear issues to the "Released" state when a GitHub release is published. Finds PRs between releases, extracts Linear issue IDs, and moves matching issues from "Ready for Release" to "Released".

**Location:** `.github/actions/linear-release-sync`

**Usage:**

```yaml
- name: Sync Linear issues
  uses: loft-sh/github-actions/.github/actions/linear-release-sync@linear-release-sync/v1
  with:
    release-tag: ${{ needs.publish.outputs.release_version }}
    repo-name: my-repo
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
    linear-token: ${{ secrets.LINEAR_TOKEN }}
```

See [linear-release-sync README](./.github/actions/linear-release-sync/README.md) for detailed documentation.

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

### Auto-approve bot PRs

Approves (and optionally enables auto-merge on) PRs from trusted bot accounts
whose title or branch matches a known safe pattern (`chore:` / `fix(deps):` /
`backport/` / `renovate/` / `update-platform-version-`). Hardened to **never
block caller CI**: `continue-on-error: true` on the job, every shell step
catches its own errors and exits 0, self-approval is pre-empted before calling
the external approve action.

**Location:** `.github/workflows/auto-approve-bot-prs.yaml`

**Usage:**

```yaml
name: Auto-approve bot PRs

on:
  pull_request:
    types: [opened, synchronize]

jobs:
  auto-approve:
    permissions:
      pull-requests: write
      contents: read
    uses: loft-sh/github-actions/.github/workflows/auto-approve-bot-prs.yaml@main
    with:
      trusted-authors: 'renovate[bot],loft-bot,github-actions[bot],dependabot[bot]'
      auto-merge: false
    secrets:
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

`gh-access-token` must be a PAT whose identity differs from PR authors you want
to auto-approve (GitHub forbids self-review). When identity matches, the job
skips gracefully instead of failing.

**End-to-end coverage:** scenario-level e2e lives in
[vClusterLabs-Experiments/auto-approve-e2e](https://github.com/vClusterLabs-Experiments/auto-approve-e2e).
Runs weekly and on demand. Creates real PRs exercising every decision-table
branch (chore/fix(deps) titles, backport/renovate/update-platform-version
branches, ineligible titles) and asserts the never-hard-fail invariant.

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

### Publish Helm Chart

Packages a Helm chart and pushes one tarball per version to ChartMuseum.
Handles release pushes (single semver, optional `--app-version`) and head
pushes (multiple `0.0.0-*` versions) under the same contract. Optionally
re-pushes the repo's highest semver afterwards so it stays first in the
upload-ordered ChartMuseum index.

**Location:** `.github/workflows/publish-helm-chart.yaml`

**Usage (release push):**

```yaml
jobs:
  publish-chart:
    permissions:
      contents: read
    uses: loft-sh/github-actions/.github/workflows/publish-helm-chart.yaml@publish-helm-chart/v1
    with:
      chart-name: vcluster
      app-version: 1.2.3
      chart-versions: '["1.2.3"]'
      ref: v1.2.3
    secrets:
      chart-museum-user: ${{ secrets.CHART_MUSEUM_USER }}
      chart-museum-password: ${{ secrets.CHART_MUSEUM_PASSWORD }}
```

**Usage (head/dev push):**

```yaml
jobs:
  push-head-chart:
    permissions:
      contents: read
    uses: loft-sh/github-actions/.github/workflows/publish-helm-chart.yaml@publish-helm-chart/v1
    with:
      chart-name: vcluster-head
      chart-description: "vCluster HEAD - Development builds from main branch"
      app-version: head-${{ github.sha }}
      chart-versions: '["0.0.0-latest","0.0.0-${{ github.sha }}"]'
    secrets:
      chart-museum-user: ${{ secrets.CHART_MUSEUM_USER }}
      chart-museum-password: ${{ secrets.CHART_MUSEUM_PASSWORD }}
```

**Inputs:**

- `chart-name` (required): chart name written to `Chart.yaml` and used in the tarball filename
- `chart-description` (optional): value written to `.description` in `Chart.yaml`
- `app-version` (optional): passed as `--app-version` to `helm package`
- `chart-versions` (required): JSON array of versions, e.g. `'["1.2.3"]'`
- `chart-directory` (optional, default: `chart`): chart source path
- `values-edits` (optional): newline-separated `jsonpath=value` pairs applied via yq to `<chart-directory>/values.yaml`
- `helm-version` (optional, default: `v3.20.0`)
- `ref` (optional): git ref to checkout (e.g. release tag)
- `republish-latest` (optional, default: `false`): re-push highest semver to keep it first in the ChartMuseum index
- `chart-museum-url` (optional, default: `https://charts.loft.sh/`)

**Secrets:** `chart-museum-user`, `chart-museum-password`.

### Govulncheck

Runs [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck)
against a Go module and, on scheduled runs, posts a Slack notification
(via `ci-test-notify`) when vulnerabilities are found. The scan always
marks the job failed on vulnerabilities — notification is the side
channel, not the gate.

**Location:** `.github/workflows/govulncheck.yaml`

**Usage (public repo, weekly schedule):**

```yaml
name: govulncheck

on:
  schedule:
    - cron: "0 12 * * 1" # Mon 12:00 UTC
  workflow_dispatch:
  pull_request:
    paths:
      - ".github/workflows/govulncheck.yaml"

jobs:
  scan:
    permissions:
      contents: read
    uses: loft-sh/github-actions/.github/workflows/govulncheck.yaml@govulncheck/v1
    secrets:
      slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

**Usage (private repo that depends on `github.com/loft-sh/*`):**

```yaml
jobs:
  scan:
    permissions:
      contents: read
    uses: loft-sh/github-actions/.github/workflows/govulncheck.yaml@govulncheck/v1
    with:
      scan-paths: "./... ./cmd/..."
      runs-on: large-8_32
      private-repo: true
    secrets:
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
      slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

**Inputs:**

- `scan-paths` (optional, default: `./...`): space-separated Go package patterns
- `test-flag` (optional, default: `true`): pass `-test` to govulncheck
- `go-version-file` (optional, default: `go.mod`): passed to `actions/setup-go`
- `runs-on` (optional, default: `ubuntu-latest`)
- `private-repo` (optional, default: `false`): enable git url rewrite + `GOPRIVATE`
- `goprivate` (optional, default: `github.com/loft-sh/*`)
- `govulncheck-version` (optional, default: `latest`)
- `timeout-minutes` (optional, default: `10`)
- `test-name` (optional, default: `govulncheck`): Slack header
- `notify` (optional, default: `true`): send Slack on vulnerabilities; fires on `schedule` events only

**Secrets:**

- `gh-access-token` (required when `private-repo: true`)
- `slack-webhook-url` (required when `notify: true` and the run is on `schedule`)

## Testing

Run all action tests locally:

```bash
make test
```

Run tests for a specific action:

```bash
make test-semver-validation
make test-linear-pr-commenter
make test-linear-release-sync
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
- `test-linear-release-sync.yaml` - triggers on `.github/actions/linear-release-sync/**`
- `release-linear-release-sync.yaml` - builds and publishes the binary on tag push or `workflow_dispatch`

Each reusable workflow (`workflow_call`) also has a smoke/integration test
workflow that triggers on PRs when the workflow file changes:

- `test-validate-renovate.yaml` - calls `validate-renovate.yaml` with local ref.
  **Note:** When triggered by workflow YAML changes alone, the inner `paths-filter`
  won't match any renovate config files so `npx renovate-config-validator` never runs.
  The validator only exercises its full path when `renovate.json` is also changed.
- `test-detect-changes.yaml` - calls `detect-changes.yaml` and asserts outputs (true/false)
- `test-actionlint-workflow.yaml` - calls `actionlint.yaml` with `github-pr-check` reporter (PR-only).
  **Note:** `actionlint.yaml` skips fork PRs silently; the verify job emits a warning when this happens.
- `test-backport.yaml` - calls `backport.yaml` and asserts the result is `skipped`
- `test-clean-github-cache.yaml` - calls `clean-github-cache.yaml` (PR-only, since the
  underlying workflow needs `github.event.pull_request.number`)
- `test-cleanup-backport-branches.yaml` - calls `cleanup-backport-branches.yaml` with `dry-run: true`
- `test-conflict-check.yaml` - calls `conflict-check.yaml` and asserts success or skipped
- `test-claude-code-review.yaml` - calls `claude-code-review.yaml` to validate workflow is callable
- `test-claude.yaml` - calls `claude.yaml` and asserts `skipped` (no `@claude` comment event)
- `test-notify-release.yaml` - calls `notify-release.yaml` with dummy inputs to validate the contract

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


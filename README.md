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

### Run Ginkgo Tests

Runs Ginkgo tests with directory or label-based filtering and generates a
JSON failure summary. Runtime-agnostic — callers handle their own cluster and
image setup (vind, Kind, bare Docker).

**Location:** `.github/actions/run-ginkgo`

**Usage:**

```yaml
- name: Run E2E tests
  id: e2e
  uses: loft-sh/github-actions/.github/actions/run-ginkgo@run-ginkgo/v1
  with:
    ginkgo-label: "my-suite && !non-default"
    test-image: ghcr.io/loft-sh/vcluster:dev
    # test-image-flag: "--platform-image"  # default: --vcluster-image
    # additional-ginkgo-flags: "-v --skip-package=linters"
    # additional-args: "--use-license-server=false"

- name: Notify on failure
  if: failure()
  uses: loft-sh/github-actions/.github/actions/ci-test-notify@ci-test-notify/v1
  with:
    test-name: "E2E Tests"
    status: failure
    details: ${{ steps.e2e.outputs.failure-summary }}
    webhook-url: ${{ secrets.SLACK_WEBHOOK }}
```

**Inputs:**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `test-image` | yes | | Image passed to the test binary |
| `test-image-flag` | no | `--vcluster-image` | CLI flag name for the image |
| `timeout` | no | `60m` | Ginkgo test timeout |
| `procs` | no | `8` | Parallel Ginkgo processes |
| `test-dir` | no | | Directory-based test selection (mutually exclusive with `ginkgo-label`) |
| `ginkgo-label` | no | | Label-based test selection (mutually exclusive with `test-dir`) |
| `append-pr-label` | no | `true` | Append `\|\| pr` to the label filter |
| `e2e-dir` | no | `e2e-next` | Root test directory |
| `additional-args` | no | | Extra args for the test binary (after `--`) |
| `additional-ginkgo-flags` | no | | Extra ginkgo CLI flags |

**Outputs:**

- `failure-summary`: Markdown-formatted test results summary

### Sticky PR Comment

Upserts a sticky comment on a pull request, identified by a stable HTML
marker. If a comment with the marker already exists it is updated in place,
otherwise a new comment is created. Domain-agnostic — the caller composes
the body. Useful for surfacing the last real run of a CI signal that the
caller skips on some events (e.g. e2e tests skipped when PR description is
unchanged), so reviewers always see the most recent meaningful result.

**Location:** `.github/actions/sticky-pr-comment`

**Usage:**

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Run tests
        id: tests
        run: ./run-tests.sh

      - name: Upsert sticky status comment
        if: always() && github.event_name == 'pull_request'
        uses: loft-sh/github-actions/.github/actions/sticky-pr-comment@sticky-pr-comment/v1
        with:
          marker: '<!-- e2e-status -->'
          body: |
            ### E2E Tests
            Status: ${{ steps.tests.outcome }}
            Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

**Inputs:**

- `marker` (required): HTML comment uniquely identifying this comment stream (form `<!-- some-id -->`)
- `body` (required): markdown body (the marker is auto-prepended when missing)
- `pr-number` (optional, default: current PR)
- `repo` (optional, default: current repo)
- `github-token` (required): token with `pull-requests: write`

**Outputs:**

- `comment-id`: numeric ID of the upserted comment
- `action-taken`: `created` or `updated`

The action is intended to be invoked from inside the job whose status it
reports — when that job is skipped via `if:`, the upsert never runs and the
previous comment stays in place, which is the desired "preserve last real
result" behavior. See the action README for full details.

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

### AI step

Small reusable building block: run an AI call with a caller-supplied prompt
and input, bind the output to a JSON Schema, expose the schema-conforming
JSON as a step output. Downstream steps parse with `fromJSON(...)` and
branch on typed fields.

Structured output is the contract. Whatever the model returns is exposed
on `result` and `conclusion=success`. The action never emits `failed` — the
caller knows what empty output means for their pipeline.

**Location:** `.github/actions/ai-step`

**Usage:**

```yaml
- uses: actions/checkout@v4
  with:
    repository: loft-sh/github-actions
    ref: ai-step/v1
    sparse-checkout: .github/actions/ai-step

- id: classify
  uses: ./.github/actions/ai-step
  with:
    provider: anthropic
    effort: low
    prompt: 'Classify this diff. Return JSON matching the schema.'
    input: ${{ steps.diff.outputs.text }}
    output-schema: |
      {
        "type": "object",
        "required": ["severity", "areas"],
        "properties": {
          "severity": { "type": "string", "enum": ["low","medium","high"] },
          "areas":    { "type": "array",  "items": { "type": "string" } }
        }
      }
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}

- if: fromJSON(steps.classify.outputs.result).severity == 'high'
  run: echo "needs human review"
```

See [ai-step README](./.github/actions/ai-step/README.md) for inputs,
outputs, and provider asymmetries.

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

**Location:** `.github/actions/publish-helm-chart`

**Usage (release push):**

```yaml
jobs:
  publish-chart:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          ref: v1.2.3
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/publish-helm-chart@publish-helm-chart/v2
        with:
          chart-name: vcluster
          app-version: 1.2.3
          chart-versions: '["1.2.3"]'
          chart-museum-user: ${{ secrets.CHART_MUSEUM_USER }}
          chart-museum-password: ${{ secrets.CHART_MUSEUM_PASSWORD }}
```

**Usage (head/dev push):**

```yaml
jobs:
  push-head-chart:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/publish-helm-chart@publish-helm-chart/v2
        with:
          chart-name: vcluster-head
          chart-description: "vCluster HEAD - Development builds from main branch"
          app-version: head-${{ github.sha }}
          chart-versions: '["0.0.0-latest","0.0.0-${{ github.sha }}"]'
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
- `helm-version` (optional, default: `v4.1.4`)
- `republish-latest` (optional, default: `"false"`): re-push highest semver to keep it first in the ChartMuseum index
- `chart-museum-url` (optional, default: `https://charts.loft.sh/`)
- `chart-museum-user` (required)
- `chart-museum-password` (required)

**Note:** The `ref` input was removed — the caller owns `actions/checkout` and checks out the desired ref directly.

### Govulncheck

Runs [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck)
against a Go module and, on scheduled runs, posts a Slack notification
(via `ci-test-notify`) when vulnerabilities are found. The scan always
marks the job failed on vulnerabilities — notification is the side
channel, not the gate.

**Location:** `.github/actions/govulncheck`

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
    runs-on: ubuntu-latest
    if: github.repository_owner == 'loft-sh'
    permissions:
      contents: read
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/govulncheck@govulncheck/v1
        with:
          slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

**Usage (private repo that depends on `github.com/loft-sh/*`):**

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    if: github.repository_owner == 'loft-sh'
    permissions:
      contents: read
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/govulncheck@govulncheck/v1
        with:
          scan-paths: "./... ./cmd/..."
          private-repo: "true"
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
          slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

**Inputs:**

- `scan-paths` (optional, default: `./...`): space-separated Go package patterns
- `test-flag` (optional, default: `true`): pass `-test` to govulncheck
- `go-version-file` (optional, default: `go.mod`): passed to `actions/setup-go`
- `private-repo` (optional, default: `false`): enable git url rewrite + `GOPRIVATE`
- `goprivate` (optional, default: `github.com/loft-sh/*`)
- `govulncheck-version` (optional, default: `latest`)
- `test-name` (optional, default: `govulncheck`): Slack header
- `notify` (optional, default: `true`): send Slack on vulnerabilities; fires on `schedule` events only
- `gh-access-token` (required when `private-repo: true`)
- `slack-webhook-url` (required when `notify: true` and the run is on `schedule`)

**Notes:**

- The caller checks out its own source and controls `runs-on`/`timeout-minutes`/fork guarding at the job level.
- A composite action cannot declare `timeout-minutes` on its steps; set `timeout-minutes` on the caller job (default ~10m is reasonable for most modules).

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
- `test-sticky-pr-comment.yaml` - triggers on `.github/actions/sticky-pr-comment/**`
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

6. Add `AUTO-DOC-INPUT`/`AUTO-DOC-OUTPUT` markers to the action's `README.md`
   and run `make generate-docs` (see [Documentation](#documentation)).

## Documentation

Action and reusable workflow documentation is auto-generated from
`action.yml` / workflow YAML using [tj-actions/auto-doc](https://github.com/tj-actions/auto-doc).
Each action README and each workflow doc in `docs/workflows/` contains
`AUTO-DOC-INPUT`, `AUTO-DOC-OUTPUT`, and `AUTO-DOC-SECRETS` marker comments
that are filled in by the tool.

Regenerate all docs locally:

```bash
make generate-docs
```

Verify docs are up to date (CI runs this on every PR):

```bash
make check-docs
```

Install the auto-doc binary only (downloaded to `.bin/`):

```bash
make install-auto-doc
```

### Workflow docs

Reusable workflow documentation lives in `docs/workflows/<workflow-name>.md`.
Each file maps 1:1 to a `workflow_call` workflow in `.github/workflows/`.

### Adding docs for a new action or workflow

1. **Action** -- add `## Inputs` and `## Outputs` sections with marker comments
   to the action's `README.md`:

   ```markdown
   ## Inputs

   <!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->
   <!-- AUTO-DOC-INPUT:END -->

   ## Outputs

   <!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->
   <!-- AUTO-DOC-OUTPUT:END -->
   ```

2. **Reusable workflow** -- create `docs/workflows/<name>.md` with `## Inputs`,
   `## Outputs` (if applicable), and `## Secrets` marker sections.

3. Run `make generate-docs` and commit the result.

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


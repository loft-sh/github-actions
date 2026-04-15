# govulncheck

Scans a Go module for known vulnerabilities using [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck).

On scheduled runs, posts a Slack notification via `ci-test-notify` when vulnerabilities are found. The scan always marks the job failed on vulnerabilities — the Slack notification is a side channel, not a gate.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `scan-paths` | Space-separated Go package patterns to scan, e.g. `./... ./cmd/...` | no | `./...` |
| `test-flag` | Pass `-test` to govulncheck (include test files in the scan) | no | `"true"` |
| `go-version-file` | Path to `go.mod` or `go.work`, passed to `actions/setup-go` | no | `go.mod` |
| `private-repo` | When `"true"`, rewrites git URLs with `gh-access-token` and sets `GOPRIVATE` for private-module resolution | no | `"false"` |
| `goprivate` | Value of `GOPRIVATE` when `private-repo: "true"` | no | `github.com/loft-sh/*` |
| `govulncheck-version` | Version of `golang.org/x/vuln/cmd/govulncheck` to install | no | `latest` |
| `test-name` | Slack notification header (passed to `ci-test-notify`) | no | `govulncheck` |
| `notify` | Send a Slack notification on vulnerabilities. Only fires on `schedule` events — PR/manual runs never notify | no | `"true"` |
| `gh-access-token` | PAT with access to private loft-sh repos. Required when `private-repo: "true"` | no | `""` |
| `slack-webhook-url` | Slack incoming webhook URL. Required when `notify: "true"` and the run is on `schedule` | no | `""` |

## Usage

Public repo, weekly schedule:

```yaml
name: govulncheck

on:
  schedule:
    - cron: "0 12 * * 1"
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

Private repo depending on `github.com/loft-sh/*`:

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

## Notes

The caller checks out its own source and controls `runs-on`, `timeout-minutes`, and fork-guarding at the job level. For large monorepos that need more memory/CPU, override `runs-on` with a larger runner label. Composite action steps cannot declare `timeout-minutes`, so set it on the caller job (10m is reasonable for most modules).

## Testing

```bash
make test-govulncheck
```

Runs the bats suite in `test/run.bats` against `run.sh` with a stubbed `govulncheck` binary.

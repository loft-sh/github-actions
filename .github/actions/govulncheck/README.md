# govulncheck

Scans a Go module for known vulnerabilities using [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck).

On scheduled runs, posts a Slack notification via `ci-test-notify` when vulnerabilities are found. The scan always marks the job failed on vulnerabilities — the Slack notification is a side channel, not a gate.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|        INPUT        |  TYPE  | REQUIRED |         DEFAULT          |                                                                         DESCRIPTION                                                                          |
|---------------------|--------|----------|--------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   gh-access-token   | string |  false   |                          |                                      PAT with access to private loft-sh <br>repos. Required when `private-repo: true`.                                       |
|   go-version-file   | string |  false   |        `"go.mod"`        |                                                 Path to go.mod (or go.work) passed to <br>actions/setup-go.                                                  |
|      goprivate      | string |  false   | `"github.com/loft-sh/*"` |                                               Value of the GOPRIVATE env var <br>when `private-repo` is true.                                                |
| govulncheck-version | string |  false   |        `"latest"`        |                                                   Version of golang.org/x/vuln/cmd/govulncheck to install.                                                   |
|       notify        | string |  false   |         `"true"`         |                    Send a Slack notification on vulnerabilities. <br>Only fires on `schedule` events — <br>PR/manual runs never notify.                      |
|    private-repo     | string |  false   |        `"false"`         | When true, configures `git` url rewriting <br>with `gh-access-token` and sets `GOPRIVATE=github.com/loft-sh/*` so <br>the scan can resolve private modules.  |
|     scan-paths      | string |  false   |        `"./..."`         |                                        Space-separated Go package patterns to scan. <br>Example: `./... ./cmd/...`.                                          |
|  slack-webhook-url  | string |  false   |                          |             Slack incoming webhook URL for the <br>ci-test-notify action. Required when `notify: true` and <br>the workflow runs on `schedule`.              |
|      test-flag      | string |  false   |         `"true"`         |                                                Pass `-test` to govulncheck (include test files in the scan).                                                 |
|      test-name      | string |  false   |     `"govulncheck"`      |                                                    Slack notification header (passed to ci-test-notify).                                                     |

<!-- AUTO-DOC-INPUT:END -->

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

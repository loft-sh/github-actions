# go-licenses

Runs [go-licenses](https://github.com/google/go-licenses) against a Go module in one of two modes:

- **`check`** — scan the module, fail the job (or warn, per `fail-on-error`) if any dependency has an incompatible license.
- **`report`** — render a license report via a Go template and open a PR with the updated file.

Both modes share the same setup (setup-go, install go-licenses, optional private-repo git auth) and differ only in the trailing steps.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|        INPUT        |  TYPE  | REQUIRED |          DEFAULT          |                                                                                                       DESCRIPTION                                                                                                       |
|---------------------|--------|----------|---------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    fail-on-error    | string |  false   |         `"true"`          | [check mode] When `false`, non-zero exit <br>codes from go-licenses are surfaced as <br>a workflow warning instead of a <br>failure. Use only as a temporary <br>escape hatch when upstream go-licenses is <br>broken.  |
|   gh-access-token   | string |  false   |                           |                                         GitHub PAT used to fetch private <br>loft-sh modules (both modes) and to open <br>the generated pull request (report mode, required).                                           |
| go-licenses-version | string |  false   |        `"v1.6.0"`         |                                    Version of go-licenses to install (e.g. v1.6.0, v1.0.0). <br>v1.0.0 does not support `--ignore` — <br>set `package-mode: go-work` when using it.                                     |
|   go-version-file   | string |  false   |        `"go.mod"`         |                                                                                      Path to go.mod or go.work for <br>setup-go.                                                                                        |
|  ignored-packages   | string |  false   |  `"github.com/loft-sh"`   |                    Comma-separated package path prefixes to skip. <br>In `all` mode these become `--ignore` <br>flags; in `go-work` mode they are <br>substring-matched against go.work DiskPaths.                      |
|        mode         | string |   true   |                           |                                  `check` — run `go-licenses check` against the module. <br>`report` — render a license report with <br>a template and open a PR <br>with the output.                                    |
|     output-path     | string |  false   |                           |                                         [report mode, required] File path in <br>the caller repo to write the <br>rendered report to, e.g. `docs/pages/licenses/vcluster.mdx`.                                          |
|    package-mode     | string |  false   |          `"all"`          |           Package selection strategy: `all` (pass `./...` with `--ignore` flags) or <br>`go-work` (enumerate modules via `go work edit` and filter at the package list — required for go-licenses < v1.6.0).            |
|      pr-branch      | string |  false   |                           |                                                                       [report mode, required] Branch name to <br>push the rendered report onto.                                                                         |
|  pr-commit-message  | string |  false   |                           |                                                                [report mode] Commit message for the <br>generated pull request. Defaults to `pr-title`.                                                                 |
|      pr-title       | string |  false   |                           |                                                                          [report mode, required] PR title for <br>the generated pull request.                                                                           |
|    template-path    | string |  false   | `".github/licenses.tmpl"` |                                                                [report mode] Path to the go-licenses <br>.tmpl template used to render the <br>report.                                                                  |

<!-- AUTO-DOC-INPUT:END -->

## Usage

### Check (single-module repo, public)

```yaml
name: go-licenses check

on:
  pull_request:
    paths:
      - 'go.mod'
      - 'go.sum'

jobs:
  check:
    runs-on: ubuntu-latest
    if: github.repository_owner == 'loft-sh'
    permissions:
      contents: read
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/go-licenses@go-licenses/v1
        with:
          mode: check
```

### Check (go.work monorepo with private modules, older go-licenses)

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    if: github.repository_owner == 'loft-sh'
    permissions:
      contents: read
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/go-licenses@go-licenses/v1
        with:
          mode: check
          go-licenses-version: v1.0.0
          go-version-file: go.work
          package-mode: go-work
          ignored-packages: github.com/loft-sh
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

### Report (render file + open PR)

```yaml
jobs:
  report:
    runs-on: ubuntu-latest
    if: github.repository_owner == 'loft-sh'
    permissions:
      contents: write
      pull-requests: write
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/go-licenses@go-licenses/v1
        with:
          mode: report
          template-path: .github/licenses.tmpl
          output-path: docs/pages/licenses/vcluster.mdx
          pr-branch: licenses/vcluster
          pr-title: "Update vcluster licenses"
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

## Testing

```bash
make test-go-licenses
```

Runs the bats suite in `test/run.bats` against `run.sh` with stubbed `go-licenses` and `go work` binaries.

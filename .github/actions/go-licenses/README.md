# go-licenses

Runs [go-licenses](https://github.com/google/go-licenses) against a Go module in one of two modes:

- **`check`** — scan the module, fail the job (or warn, per `fail-on-error`) if any dependency has an incompatible license.
- **`report`** — render a license report via a Go template and open a PR with the updated file.

Both modes share the same setup (setup-go, install go-licenses, optional private-repo git auth) and differ only in the trailing steps.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `mode` | `check` or `report` | yes | — |
| `go-licenses-version` | go-licenses version to install. `v1.0.0` lacks `--ignore`; use `package-mode: go-work` with it | no | `v1.6.0` |
| `go-version-file` | Passed to `actions/setup-go` | no | `go.mod` |
| `ignored-packages` | Comma-separated package path prefixes to skip. In `all` mode → `--ignore` flags; in `go-work` mode → substring-matched against `go.work` DiskPaths | no | `github.com/loft-sh` |
| `package-mode` | `all` (pass `./...` + `--ignore`) or `go-work` (enumerate workspace modules — required for go-licenses < v1.6.0) | no | `all` |
| `fail-on-error` | [check] When `"false"`, non-zero go-licenses exit is surfaced as a warning; the step still succeeds | no | `"true"` |
| `template-path` | [report] Path to the go-licenses .tmpl template | no | `.github/licenses.tmpl` |
| `output-path` | [report] File path to write the rendered report to | required for `report` | `""` |
| `pr-branch` | [report] Branch name for the generated PR | required for `report` | `""` |
| `pr-title` | [report] PR title | required for `report` | `""` |
| `pr-commit-message` | [report] Commit message; defaults to `pr-title` | no | `""` |
| `gh-access-token` | GitHub PAT — fetches private loft-sh modules (both modes) and opens the PR (report mode) | required for `report`, optional for private-module `check` | `""` |

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

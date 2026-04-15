# publish-helm-chart

Packages a Helm chart and pushes it to ChartMuseum. Handles multi-version publishes, in-place `Chart.yaml` / `values.yaml` edits via yq, and optional latest-semver re-push for stable release streams.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `chart-name` | Written to `.name` in `Chart.yaml`; also determines the packaged tarball filename | yes | — |
| `chart-description` | Optional value written to `.description` in `Chart.yaml`. Preserved when empty | no | `""` |
| `app-version` | Passed as `--app-version` to `helm package`. When empty, the chart's existing `appVersion` is used | no | `""` |
| `chart-versions` | JSON array of chart versions. Each entry is packaged and pushed as `<chart-name>-<version>.tgz`. Examples: `'["1.2.3"]'`, `'["0.0.0-latest","0.0.0-abc1234"]'` | yes | — |
| `chart-directory` | Path to the Helm chart source directory | no | `chart` |
| `values-edits` | Newline-separated `jsonpath=value` pairs applied via yq to `<chart-directory>/values.yaml`. Values are written as strings | no | `""` |
| `helm-version` | Helm CLI version to install | no | `v4.1.4` |
| `republish-latest` | When `"true"`, after pushing, re-push the highest semver so it becomes the most recently uploaded entry (for stable release streams) | no | `"false"` |
| `chart-museum-url` | ChartMuseum base URL | no | `https://charts.loft.sh/` |
| `chart-museum-user` | ChartMuseum username | yes | — |
| `chart-museum-password` | ChartMuseum password | yes | — |

## Usage

### Head chart on push-to-main

```yaml
name: Push head images

on:
  push:
    branches: [main]

jobs:
  publish-head-chart:
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
          app-version: head-${{ github.sha }}
          chart-versions: '["0.0.0-latest","0.0.0-${{ github.sha }}"]'
          chart-museum-user: ${{ secrets.CHART_MUSEUM_USER }}
          chart-museum-password: ${{ secrets.CHART_MUSEUM_PASSWORD }}
```

### Release chart (custom ref + dual product)

```yaml
jobs:
  publish-release-chart:
    runs-on: ubuntu-24.04
    strategy:
      matrix:
        product:
          - {name: loft,              description: "Loft chart"}
          - {name: vcluster-platform, description: "vCluster Platform chart"}
    permissions:
      contents: read
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          ref: ${{ github.event.release.tag_name }}
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/publish-helm-chart@publish-helm-chart/v2
        with:
          chart-name: ${{ matrix.product.name }}
          chart-description: ${{ matrix.product.description }}
          chart-versions: '["${{ inputs.release_version }}"]'
          values-edits: |
            .product=${{ matrix.product.name }}
          republish-latest: "true"
          chart-museum-user: ${{ secrets.CHART_MUSEUM_USER }}
          chart-museum-password: ${{ secrets.CHART_MUSEUM_PASSWORD }}
```

## Notes

The caller owns `actions/checkout` — so to publish a specific ref (e.g. a release tag), pass it to `actions/checkout` directly rather than through this action.

## Testing

```bash
make test-publish-helm-chart
```

Runs the bats suite in `test/run.bats` against `run.sh` with stubbed `helm` and `yq` binaries. Requires `mikefarah/yq` on `PATH` for the real-yq assertions.

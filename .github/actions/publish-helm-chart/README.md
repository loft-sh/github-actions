# publish-helm-chart

Packages a Helm chart and pushes it to ChartMuseum. Handles multi-version publishes, in-place `Chart.yaml` / `values.yaml` edits via yq, and optional latest-semver re-push for stable release streams.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|         INPUT         |  TYPE  | REQUIRED |           DEFAULT           |                                                                                                                DESCRIPTION                                                                                                                 |
|-----------------------|--------|----------|-----------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|      app-version      | string |  false   |                             |                                                          Optional value passed as --app-version to <br>`helm package`. When empty, the chart's existing <br>appVersion is used.                                                            |
|   chart-description   | string |  false   |                             |                                                             Optional value written to .description in <br>Chart.yaml. When empty, the existing description <br>is preserved.                                                               |
|    chart-directory    | string |  false   |          `"chart"`          |                                                                                               Path to the Helm chart source <br>directory.                                                                                                 |
| chart-museum-password | string |   true   |                             |                                                                                                           ChartMuseum password.                                                                                                            |
|   chart-museum-url    | string |  false   | `"https://charts.loft.sh/"` |                                                                                                           ChartMuseum base URL.                                                                                                            |
|   chart-museum-user   | string |   true   |                             |                                                                                                           ChartMuseum username.                                                                                                            |
|      chart-name       | string |   true   |                             |                                                                  Helm chart name. Written to .name <br>in Chart.yaml; also determines the packaged <br>tarball filename.                                                                   |
|    chart-versions     | string |   true   |                             |                            JSON array of chart versions to <br>publish. Each entry is packaged and <br>pushed as <chart-name>-<version>.tgz. Examples: '["1.2.3"]' or <br>'["0.0.0-latest","0.0.0-abc1234"]'.                              |
|     helm-version      | string |  false   |         `"v4.1.4"`          |                                                                                                        Helm CLI version to install.                                                                                                        |
|   republish-latest    | string |  false   |          `"false"`          | When true, after pushing, query ChartMuseum <br>for the highest semver of <chart-name> <br>and re-push it so it becomes <br>the most recently uploaded entry. Use <br>for stable release publishing into a <br>multi-line release stream.  |
|     values-edits      | string |  false   |                             |                                                 Optional newline-separated `jsonpath=value` pairs applied via <br>yq to <chart-directory>/values.yaml. Values are written <br>as strings.                                                  |

<!-- AUTO-DOC-INPUT:END -->

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

# Bump manifest image

Opens a pull request that bumps a container's image tag in a Kubernetes
deployment manifest, for a single environment. Domain-agnostic — the caller
supplies the manifest path, container name, image repo, and tag. It is
semver-aware (never downgrades), skips pre-releases for `prod`, and can enable
auto-merge on the PR it opens. Call it from a matrix over environments to fan a
single release out to staging and prod.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT      |  TYPE  | REQUIRED |  DEFAULT  |                                                                                                          DESCRIPTION                                                                                                          |
|----------------|--------|----------|-----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   auto-merge   | string |  false   | `"false"` |                                                                                   Enable GitHub auto-merge (squash) on the <br>opened PR.                                                                                     |
|  base-branch   | string |  false   | `"main"`  |                                                                                                    Base branch for the PR.                                                                                                    |
| container-name | string |   true   |           |                                                                                    Name of the container whose image <br>tag is tracked.                                                                                      |
|  environment   | string |   true   |           |                                                                                      Target environment. "prod" skips pre-release tags.                                                                                       |
|   image-repo   | string |   true   |           |                                                                               Image repo without tag (e.g. ghcr.io/loft-sh/revops-events-api).                                                                                |
| manifest-path  | string |   true   |           |                                                                                         Path to the deployment manifest to <br>edit.                                                                                          |
|      tag       | string |   true   |           |                                                                                     Release tag to roll out (e.g. v0.2.0 or 0.2.0-rc1).                                                                                       |
|     token      | string |   true   |           | PAT used to open the PR <br>and (if enabled) enable auto-merge. Must be <br>a PAT or App token, not <br>GITHUB_TOKEN: a GITHUB_TOKEN merge emits no <br>events, so downstream merge-triggered workflows would <br>never run.  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|       OUTPUT        |  TYPE  |                             DESCRIPTION                              |
|---------------------|--------|----------------------------------------------------------------------|
| pull-request-number | string |           Number of the opened PR (empty when no update).            |
|       updated       | string | true when a PR was opened <br>(a newer applicable version existed).  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
on:
  repository_dispatch:
    types: [update-my-app-version]
  workflow_dispatch:
    inputs:
      tag:
        description: 'Image tag to roll out (e.g. v0.2.0)'
        required: true

jobs:
  bump:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [staging, prod]
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/bump-manifest-image@bump-manifest-image/v1
        with:
          tag: ${{ github.event.client_payload.tag || inputs.tag }}
          environment: ${{ matrix.environment }}
          manifest-path: kubernetes/manifests/${{ matrix.environment }}/my-app/deployment.yaml
          container-name: my-app
          image-repo: ghcr.io/loft-sh/my-app
          auto-merge: ${{ matrix.environment == 'staging' }}
          token: ${{ secrets.GH_ACCESS_TOKEN }}
```

### Auth

`token` must be a Personal Access Token or GitHub App token (not
`GITHUB_TOKEN`). It opens the PR and, when `auto-merge` is enabled, performs
the merge. A merge performed with `GITHUB_TOKEN` emits no events, so any
downstream merge-triggered workflow (for example a deploy notification) would
never run.

### Behaviour

- **Semver-aware** — the PR is only opened when `tag` is strictly newer than
  the tag currently in the manifest. Equal or older versions are a no-op.
- **Prod safety** — pre-release tags (anything that is not a bare `X.Y.Z`) are
  skipped when `environment` is `prod`.
- **PR shape** — title and branch are derived from the image repo's last path
  segment, e.g. `chore(my-app): bump staging to v0.2.0` on branch
  `update-staging-my-app-0.2.0`.

## Testing

```bash
make test-bump-manifest-image
```

Runs the bats suites in `test/` against the `src/` scripts. `yq` must be on
`PATH` (pre-installed on GitHub hosted runners).

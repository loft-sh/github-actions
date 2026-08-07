# Resolve GitHub release

Resolves a release version input to a concrete tag: `latest` (or `main`)
becomes the tag of the repository's latest published release, anything else
passes through unchanged.

CI workflows that consume another repo's release artifacts usually accept a
version input defaulting to `latest`. Every artifact URL they build needs a
real tag, and `latest` resolves differently over time, so each workflow ends up
with the same inline resolve-and-record shell. This action centralizes it and
appends the resolved tag to the step summary as an audit trail of what the run
actually used.

An explicit tag is deliberately **not** checked for existence: callers may pass
tags for releases that are still publishing, and ordering on a release that is
about to appear is [wait-for-release](../wait-for-release)'s job. The artifact
download fails loudly on a bad tag anyway.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT     |  TYPE  | REQUIRED | DEFAULT |                                                                DESCRIPTION                                                                 |
|--------------|--------|----------|---------|--------------------------------------------------------------------------------------------------------------------------------------------|
| github-token | string |   true   |         |                                                    Token with contents:read on `repo`.                                                     |
|     repo     | string |   true   |         |                               Repository publishing the release, as owner/name <br>(e.g. loft-sh/vcluster).                                |
|   version    | string |   true   |         | Version to resolve: "latest" or "main" <br>resolve to the latest published release <br>tag; any other value passes through <br>unchanged.  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

| OUTPUT |  TYPE  |        DESCRIPTION        |
|--------|--------|---------------------------|
|  tag   | string | The resolved release tag. |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
- name: Resolve vCluster OSS release
  id: resolve-release
  uses: loft-sh/github-actions/.github/actions/resolve-github-release@resolve-github-release/v1
  with:
    repo: loft-sh/vcluster
    version: ${{ inputs.vcluster_cli_version }}
    github-token: ${{ github.token }}

- name: Download standalone binary
  run: |
    curl -fsSL --retry 3 \
      "https://github.com/loft-sh/vcluster/releases/download/${{ steps.resolve-release.outputs.tag }}/vcluster-linux-amd64-standalone" \
      -o ./vcluster-standalone-binary
```

## Permissions

`contents: read` on `repo`. For a public repo the default `GITHUB_TOKEN` is
enough; for a private cross-repo lookup pass a token with read access to the
target repo.

## Tests

```bash
make test-resolve-github-release
```

Bats tests against a `gh` stub on `PATH`: no token, no network. The stub counts
API calls, so the pass-through path is asserted to never touch the API.

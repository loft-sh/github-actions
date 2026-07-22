# Promote Release

Retags the moving docker tags (`:latest`, `:{major}`, `:{major}.{minor}`, and
any configured suffix variant such as `-fips`) onto the digest of an already
published, already signed version tag — a manifest copy via
`docker buildx imagetools create`, never a rebuild, so cosign signatures (OCI
referrers, digest-scoped) stay valid with no re-signing. Optionally also
promotes a paired public release in a companion repo (unsets `prerelease`,
sets `latest`).

Wire this from `on: release: types: [released]` on the repo that owns the
moving tags. That event only fires when a human — not `GITHUB_TOKEN`/a bot —
flips a release from pre-release to a full release (verified live for
DEVOPS-1083); a bot-authored release publish never triggers it, so there is
no risk of the build itself re-entering this action.

Only acts on a stable `vX.Y.Z` version (no prerelease suffix); any other shape
is a no-op, since moving tags and "latest" promotion aren't meaningful for
`-rc`/`-alpha`/`-next` cuts.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT     |  TYPE  | REQUIRED | DEFAULT |                                                                                        DESCRIPTION                                                                                        |
|--------------|--------|----------|---------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| version      | string |   true   |         | The promoted release tag, e.g. v0.37.1.                                                                                                                                                      |
| images       | string |   true   |         | JSON array of image entries to retag, each `{"image": "ghcr.io/loft-sh/x", "suffix": ""}` (suffix optional, default ""). Copies `<image>:<version><suffix>` to the three moving tags below. |
| oss-repo     | string |  false   | `""`    | owner/repo whose matching `<version>` release should also be promoted (prerelease unset, latest set). Leave empty to skip.                                                                  |
| github-token | string |   true   |         | Token with GHCR write:packages, and contents:write on oss-repo if set.                                                                                                                       |
| dry-run      | string |  false   | `false` | "true" prints the planned retags/promotion without executing them.                                                                                                                           |

<!-- AUTO-DOC-INPUT:END -->

## Usage

```yaml
on:
  release:
    types: [released]

jobs:
  promote:
    if: github.event.release.prerelease == false
    runs-on: ubuntu-latest
    permissions:
      packages: write
      contents: read
    steps:
      - name: Promote release
        uses: loft-sh/github-actions/.github/actions/promote-release@<sha> # promote-release/v1
        with:
          version: ${{ github.event.release.tag_name }}
          oss-repo: loft-sh/vcluster
          github-token: ${{ secrets.GH_ACCESS_TOKEN }}
          images: |
            [
              {"image": "ghcr.io/loft-sh/vcluster-pro"},
              {"image": "ghcr.io/loft-sh/vcluster-pro", "suffix": "-fips"},
              {"image": "ghcr.io/loft-sh/vcluster-pro-fips"},
              {"image": "ghcr.io/loft-sh/vcluster-oss"},
              {"image": "ghcr.io/loft-sh/vcluster-cli"}
            ]
```

### Why this needs a build-time gating change too

This action only *retags* — the moving tags must not already exist from the
build. The caller's `.goreleaser.yaml` (or equivalent) must publish only the
immutable `:<version>` tag at build time and never the moving tags, and the
GitHub Release itself must be created as a pre-release (`prerelease: true`,
not `auto`) so there is a real pre-release → full-release edit for a human to
make — otherwise `release: types: [released]` never fires for a stable cut.

### GHCR login

`docker buildx imagetools create` needs to push to GHCR, so log in before
calling this action (skipped automatically when `dry-run: true`):

```yaml
      - uses: docker/login-action@<sha> # v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GH_ACCESS_TOKEN }}
```

The action.yml in this directory already includes this login step, so callers
using `uses: .../promote-release@...` directly don't need to repeat it.

### oss-repo

If set, and a release matching `version` exists on `oss-repo`, it is edited
to `--prerelease=false --latest`. If no matching release exists, this step is
skipped with a warning — it does not fail the docker retagging.

## Testing

```bash
make test-promote-release
```

Runs the bats suite in `test/` against `src/action.sh` with stubbed `docker`
and `gh` on `PATH`.

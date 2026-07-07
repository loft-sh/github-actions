# Cut vCluster release

Single entry point for cutting a vCluster release on any supported line. The
version string decides the routing, so nobody has to remember which release
procedure a given version needs.

The GitHub Release is treated as a pipeline **output**, not a trigger. This
action only creates the tag(s) and dispatches each line's own `release.yaml` via
`workflow_dispatch` (`gh workflow run --ref <tag>`, which runs the tagged
commit's version of the workflow). The dispatched builder creates the release at
the end of a green build. Because no builder triggers on `release:created`, a
monorepo-created OSS release cannot re-trigger the OSS builder.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT     |  TYPE  | REQUIRED | DEFAULT  |                                                           DESCRIPTION                                                            |
|--------------|--------|----------|----------|----------------------------------------------------------------------------------------------------------------------------------|
|   dry-run    | string |  false   | `"true"` | When true (default), run the read-only <br>routing checks and print the exact <br>tag + dispatch calls without firing <br>them.  |
| github-token | string |   true   |          | Token with repo + workflow scope <br>on both loft-sh/vcluster and loft-sh/vcluster-pro (cross-repo tag creation and dispatch).   |
|   version    | string |   true   |          |                                      Release version to cut, e.g. v0.35.4 <br>or v0.36.2.                                        |

<!-- AUTO-DOC-INPUT:END -->

## Routing

Era is decided by a numeric `(major, minor)` compare against the `CUTOVER`
constant (`v0.36`):

| Era | Versions | Fan-out |
|-----|----------|---------|
| legacy | `< v0.36` | Verify the `vX.Y` branch in **both** repos, tag both, dispatch `loft-sh/vcluster` **first**, then `loft-sh/vcluster-pro`. |
| monorepo | `>= v0.36` | Resolve target (`vX.Y` line branch if it exists, else `main`), dispatch `loft-sh/vcluster-pro` only. |

Numeric compare matters: `v0.9` sorts *below* `v0.36` (legacy), and `v1.0` lands
in the monorepo era.

## Guards

- **Double-cut:** fails if the tag or a release for `version` already exists in a
  target repo.
- **Unprepared line:** fails loudly if a required `vX.Y` branch is absent (no
  silent fallback), distinguishing a real 404 from a transient API error.
- **Dry-run** still performs the read-only checks, so a bad routing decision
  (missing branch, already-released) is caught before anything is dispatched.

## Partial-failure recovery

The legacy path (tag OSS → tag pro → dispatch OSS → dispatch pro) is **not
atomic**. If a run dies partway, read the log to see how far it got before
recovering, so an interrupted cut is not mistaken for a genuine double-cut:

- **Failed during tagging** (one repo tagged, the other not, nothing dispatched):
  delete the orphaned tag and re-run the action. Nothing has been built yet.
- **Failed after the OSS dispatch** (the log shows the `::notice::` that
  `loft-sh/vcluster` was dispatched, but the pro dispatch did not run): the OSS
  build is already in flight. **Do not** delete the tags and re-run this action
  wholesale (that would dispatch OSS a second time). Instead, dispatch pro only:

  ```bash
  gh workflow run release.yaml --repo loft-sh/vcluster-pro --ref <version>
  ```

## Usage

Consumed by a `workflow_dispatch` workflow on the caller's default branch (the
single canonical release button):

```yaml
name: Cut release
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Release version to cut (e.g. v0.35.4 or v0.36.2)"
        type: string
        required: true
      dry_run:
        description: "Print the routing decision and exact calls without firing them"
        type: boolean
        required: true
        default: true

permissions:
  contents: read

jobs:
  vcluster-release:
    if: ${{ github.repository_owner == 'loft-sh' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/vcluster-release@vcluster-release/v1
        with:
          version: ${{ inputs.version }}
          dry-run: ${{ inputs.dry_run }}
          github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

### Auth

`github-token` must be a Personal Access Token or GitHub App token with `repo` +
`workflow` scope on **both** `loft-sh/vcluster` and `loft-sh/vcluster-pro`
(cross-repo tag creation and dispatch). `secrets.GITHUB_TOKEN` cannot dispatch
into other repos.

## Testing

```bash
make test-vcluster-release
```

Runs the bats suite in `test/` against `src/vcluster-release.sh` with a configurable
`gh` stub on `PATH` (no real API calls). The stub mirrors real `gh` behaviour,
including exiting non-zero on a 404.

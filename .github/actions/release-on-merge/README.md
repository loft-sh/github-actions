# Release on merge

Publish a stable GitHub release for first-parent conventional commits. `feat` increments the minor version; `fix` and `refactor` increment the patch version. A breaking `!` header or `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer increments the major version, or the minor version while the major is zero. Other commits do not cause a release. The highest reachable stable `vMAJOR.MINOR.PATCH` tag is the base; prerelease tags are ignored. With no stable tag, `initial-version` is the base, not the first published version.

The action creates a lightweight tag at the target SHA and a GitHub release with generated notes. A retry returns an existing stable release at the same target, or completes a release if its tag was created before publication failed. Conflicting remote tags fail without being moved. A retry needs freshly fetched tags. Use the outputs in the same workflow to start a build: releases created by `GITHUB_TOKEN` do not trigger a separate release-event workflow.

The caller must check out full history and tags (`fetch-depth: 0`), grant `contents: write`, and serialize release runs with a non-canceling concurrency group. The checkout must contain the target commit and all tags. Shallow or missing history fails. Python 3, Git and the GitHub CLI are required. The action makes bounded GitHub CLI requests and needs network access to GitHub.

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |         DEFAULT         |                           DESCRIPTION                           |
|-----------------|--------|----------|-------------------------|-----------------------------------------------------------------|
|  github-token   | string |  false   | `"${{ github.token }}"` | Token with contents write access to <br>the caller repository.  |
| initial-version | string |  false   |       `"v0.0.0"`        | Stable version used as the base <br>before the first release.   |
|   target-sha    | string |  false   |  `"${{ github.sha }}"`  |     Commit to release from the fully <br>fetched checkout.      |

<!-- AUTO-DOC-INPUT:END -->

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|  OUTPUT  |  TYPE  |                             DESCRIPTION                              |
|----------|--------|----------------------------------------------------------------------|
| released | string | True when a release exists for <br>this target; false when skipped.  |
| revision | string |                       Full target commit SHA.                        |
| version  | string |  Released stable version, or empty when <br>no release is needed.    |

<!-- AUTO-DOC-OUTPUT:END -->

```yaml
permissions:
  contents: write
concurrency:
  group: release-on-merge
  cancel-in-progress: false
jobs:
  release:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.release.outputs.version }}
      revision: ${{ steps.release.outputs.revision }}
      released: ${{ steps.release.outputs.released }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false
      - id: release
        uses: loft-sh/github-actions/.github/actions/release-on-merge@release-on-merge/v1
```

Run the offline Git and API fixture tests with `make test-release-on-merge`.

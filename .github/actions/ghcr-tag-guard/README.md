# GHCR tag guard

Refuse publication unless every supplied version tag is confirmed absent.
This action only reads GHCR. It never pushes, deletes, or changes a tag.

## Usage

```yaml
concurrency:
  group: release-${{ github.ref_name }}
  cancel-in-progress: false

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: loft-sh/github-actions/.github/actions/ghcr-tag-guard@ghcr-tag-guard/v1
        with:
          images: |
            ghcr.io/${{ github.repository_owner }}/kine:${{ github.ref_name }}
            ghcr.io/${{ github.repository_owner }}/kine:${{ github.ref_name }}-nocgo
      # Build and publish only after every version tag passed the check.
```

Run the guard before any release or registry write. Include every immutable tag
the job will push, including variants, in one invocation. Do not pass rolling
tags such as `latest`. Ubuntu runners provide the required Python 3 standard
library; there are no downloaded tools or Python dependencies.

GitHub owner and repository names may contain capitals in the input. The guard
lowercases the repository path for GHCR requests and preserves the tag's case.

The manifest lookup supports OCI image manifests and indexes, and Docker schema 2
manifests and manifest lists. Before publishing a new manifest format, extend the
guard's `Accept` list and its manifest-type tests. A registry can return
`MANIFEST_UNKNOWN` for an unsupported format even when the tag exists; this guard
does not prove absence for formats outside that list.

## Required permissions

The guard needs `packages: read`, with pull access to an existing GHCR package.
A publishing job normally already has `packages: write`. For another private
package, grant the workflow repository access to that package or pass an
authorized token and its username through the inputs. The token stays in the
step environment and HTTPS headers. It is never printed or written to outputs.

## Failure and retry policy

Only an HTTP 404 response whose errors are all `MANIFEST_UNKNOWN` permits
publication. An existing digest refuses publication, including the same digest
on a retry. Authentication errors, missing package access, rate limits, network
errors, redirects, malformed responses, and ambiguous 404 responses fail closed.
The log names an existing tag, its digest, and the refusal reason. Package
creation must happen through a separate approved process; `NAME_UNKNOWN` is
not proof that a version tag is safe to publish.

A draft release can be retried only before any version image has been pushed.
After a partial push, cut a new version or use a separately approved recovery
that preserves existing digests. Never delete a published tag to get past the
guard.

This preflight is a client check, not registry-enforced immutability or an
atomic reservation. All publishers of a tag must use the same per-tag
concurrency group in the same repository, with cancellation disabled. Manual
writers, historical workflow reruns, and other repositories can bypass that
lock. Native registry enforcement and credential policy remain separate controls.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT       |  TYPE  | REQUIRED |         DEFAULT         |                                       DESCRIPTION                                        |
|-------------------|--------|----------|-------------------------|------------------------------------------------------------------------------------------|
|      images       | string |   true   |                         | Newline-separated fully qualified GHCR version tags <br>to check before any publication  |
|  registry-token   | string |  false   | `"${{ github.token }}"` |      Token with packages read access; never <br>written to logs or action outputs        |
| registry-username | string |  false   | `"${{ github.actor }}"` |                   GitHub actor with pull access to <br>every package                     |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->
No outputs.
<!-- AUTO-DOC-OUTPUT:END -->

A nonzero exit blocks the caller's later steps.

## Tests

`make test-ghcr-tag-guard` runs offline tests for absent and existing tags,
supported manifest types, mixed-case repository names, retries, partial variant
publication, API and auth errors, and read-only requests. These tests exercise
the guard's lookup and refusal behavior, not a caller's publication steps.
Live read-only checks should record a digest
before and after an expected rejection. Publishing a fresh image is a release
action and needs its own authorization.

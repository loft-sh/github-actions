# UI verifier backend image

Build and push a backend-only dev image to the private UI verifier registry.
The checkout must be the exact PR head. The image contains the default fake
license and must stay private. The runner needs Docker, `just`, and the build
prerequisites from loft-enterprise. The build runs before Google authentication
because it can take longer than the federated credentials last.

Only trusted loft-enterprise PR code may run in this job. Do not grant OIDC
access to untrusted fork code. The caller must check both the PR origin and
its authorization policy before running the job. The WIF principal is limited
to loft-enterprise repository ID 246071526. The job needs `id-token: write`.

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
    with:
      ref: ${{ github.event.pull_request.head.sha }}
      persist-credentials: false
  - uses: loft-sh/github-actions/.github/actions/ui-verifier-image@ui-verifier-image/v1
    id: image
    with:
      head-sha: ${{ github.event.pull_request.head.sha }}
  - run: echo "$IMAGE"
    env:
      IMAGE: ${{ steps.image.outputs.image }}
```

This example is a job fragment, not a trigger or an authorization check. The
first `ui-verifier-image/v1` tag must be created after merge before use. The
caller is responsible for serialization, backend diff, wake, redeploy and
port-forward. A successful push does not establish that the tenant can pull or
run the image.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|  INPUT   |  TYPE  | REQUIRED | DEFAULT |                   DESCRIPTION                   |
|----------|--------|----------|---------|-------------------------------------------------|
| head-sha | string |   true   |         | Full commit SHA of the checked-out <br>PR head  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

| OUTPUT |  TYPE  |        DESCRIPTION        |
|--------|--------|---------------------------|
| image  | string | Published image reference |

<!-- AUTO-DOC-OUTPUT:END -->

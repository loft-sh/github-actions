# Testing tailnet

Connect a GitHub-hosted Linux job to the testing tailnet using a Tailscale federated identity and GitHub OIDC. The action supports trusted workflows only. It rejects `pull_request`, `pull_request_target`, and `refs/pull/*` before authentication. These checks are defense in depth, not the trust boundary.

Configure Tailscale's federated identity to trust GitHub's issuer (`https://token.actions.githubusercontent.com`), with `auth_keys` as its only scope and `tag:e2e-github-runner` as its only allowed tag. Restrict all of these claims independently on the Tailscale side for the initial smoke workflow:

```text
repository_id = 934201778
repository = loft-sh/github-actions
workflow_ref = loft-sh/github-actions/.github/workflows/testing-tailnet-smoke.yaml@refs/heads/main
ref = refs/heads/main
event_name = workflow_dispatch
sub = repo:loft-sh/github-actions:ref:refs/heads/main
```

Protect `main` and the workflow from untrusted changes. The local runner and event checks are defense in depth, not the trust boundary. Review GitHub's OIDC claims and add a separate restricted trust rule before allowing another workflow or event. Do not allow PR events or untrusted code in an authorized job. See [Tailscale WIF](https://tailscale.com/docs/features/workload-identity-federation) and [GitHub OIDC claims](https://docs.github.com/en/actions/reference/security/oidc).

The initial `testing-tailnet-smoke.yaml` workflow uses this local action and exposes a run and attempt marker on the runner's tailnet IPv4 address at TCP port 18070. Success and intentional failure modes serve for 180 seconds; cancellation mode serves for up to 900 seconds so it can be cancelled externally. Dispatch is available once the workflow is on the default branch. The workflow creates no remote test fixture.

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - id: tailnet
    uses: loft-sh/github-actions/.github/actions/testing-tailnet@testing-tailnet/v1
    with:
      client-id: ${{ vars.TS_CLIENT_ID }}
      audience: ${{ vars.TS_AUDIENCE }}
      expected-tailnet: robin-cobia.ts.net
```

Use the client ID and generated `api.tailscale.com/<client ID>` audience from the federated identity. Set the variables in the caller after the identity is configured. The action exposes `ipv4` and `node-id` outputs only after checking the running backend, exact MagicDNS suffix, and exact CI tag. The node accepts routes, does not accept DNS, and does not enable Tailscale SSH. Joining exposes routes and services permitted to the tag for the whole job; keep tailnet grants and each job's service exposure narrow.

The upstream action registers a post-job logout and requests an ephemeral node. Offline ephemeral-node removal is a fallback if logout cannot run. Normal completion, failure, and cancellation cleanup must be verified in a live test; force cancellation cleanup is not proven.

Run the local unit tests with `make test-testing-tailnet`; run actionlint and zizmor with `make lint`. No live identity is needed for unit tests. The first action-specific `testing-tailnet/v1` tag must be published after merge before callers can use the example.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED | DEFAULT |                         DESCRIPTION                          |
|------------------|--------|----------|---------|--------------------------------------------------------------|
|     audience     | string |   true   |         | Tailscale generated audience for the federated <br>identity  |
|    client-id     | string |   true   |         |            Tailscale federated identity client ID            |
| expected-tailnet | string |   true   |         |     Expected MagicDNS suffix of the testing <br>tailnet      |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

| OUTPUT  |  TYPE  |             DESCRIPTION              |
|---------|--------|--------------------------------------|
|  ipv4   | string | Tailscale IPv4 address of the runner |
| node-id | string |       Stable Tailscale node ID       |

<!-- AUTO-DOC-OUTPUT:END -->

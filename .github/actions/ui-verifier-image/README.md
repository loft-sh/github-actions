# UI verifier backend image

Build and push a backend-only dev image to the private UI verifier registry.
The image contains the default fake license and must stay private.

## Trusted caller

The action runs repository code with job-wide OIDC access. For a PR-comment
trigger, use a default-branch workflow and gate the whole publishing job.
A reviewer with write, maintain or admin permission comments
`/publish-ui-image <SHA>` with the full current PR head SHA. The gate rejects forks, closed PRs,
missing data, stale SHA values and unauthorized commenters. A later change to the
head requires a new command. The job builds the approved SHA even if the branch
moves after the gate. GitHub API errors fail the gate closed. Configure
`VERIFIER_PUBLISHER_REPOSITORY_ID` with the caller's repository ID.

```yaml
name: Publish UI verifier image
on:
  issue_comment:
    types: [created]
permissions: {}
jobs:
  gate:
    if: github.event.issue.pull_request && github.repository_id == vars.VERIFIER_PUBLISHER_REPOSITORY_ID
    runs-on: ubuntu-26.04
    permissions:
      pull-requests: read
      contents: read
    outputs:
      sha: ${{ steps.gate.outputs.sha }}
    steps:
      - id: gate
        env:
          GH_TOKEN: ${{ github.token }}
          COMMENT: ${{ github.event.comment.body }}
          ACTOR: ${{ github.event.comment.user.login }}
          PR: ${{ github.event.issue.number }}
          REPO: ${{ github.repository }}
          PUBLISHER_REPO_ID: ${{ github.repository_id }}
        shell: bash
        run: |
          set -euo pipefail
          [[ "$COMMENT" =~ ^/publish-ui-image\ ([0-9a-f]{40})$ ]] || exit 0
          approved_sha=${BASH_REMATCH[1]}
          [[ "$PR" =~ ^[0-9]+$ && "$PUBLISHER_REPO_ID" =~ ^[0-9]+$ && -n "$ACTOR" ]] || exit 0
          permission=$(gh api "repos/$REPO/collaborators/$ACTOR/permission" --jq .permission)
          case "$permission" in admin|maintain|write) ;; *) exit 0 ;; esac
          pr=$(gh api "repos/$REPO/pulls/$PR")
          jq -e --arg sha "$approved_sha" --argjson repo_id "$PUBLISHER_REPO_ID" \
            '.state == "open" and .head.repo.id == $repo_id and .base.repo.id == $repo_id and .head.sha == $sha' <<<"$pr" >/dev/null || exit 0
          echo "sha=$approved_sha" >> "$GITHUB_OUTPUT"
  publish:
    needs: gate
    if: needs.gate.outputs.sha != ''
    runs-on: ubuntu-26.04
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ needs.gate.outputs.sha }}
          fetch-depth: 0
          persist-credentials: false
      # Install the trusted builder prerequisites described below here.
      - uses: loft-sh/github-actions/.github/actions/ui-verifier-image/build@ui-verifier-image/v1
        with:
          head-sha: ${{ needs.gate.outputs.sha }}
          image-repository: ${{ vars.VERIFIER_IMAGE_REPOSITORY }}
      # Authenticate and configure Docker for the private registry in the caller.
      - uses: loft-sh/github-actions/.github/actions/ui-verifier-image/push@ui-verifier-image/v1
        id: image
        with:
          head-sha: ${{ needs.gate.outputs.sha }}
          image-repository: ${{ vars.VERIFIER_IMAGE_REPOSITORY }}
```

The gate job has no OIDC, secrets or PR checkout. Do not use this example with
`pull_request_target`, remove the job gate, or run the publisher on an untrusted
runner. Repository write access authorizes execution of that exact commit, not
just a comment on a PR. Secure the default branch and the workflow itself.

## Builder prerequisites

Install Docker, Go from `go.mod`, Just, GoReleaser v2, and Helm. Configure
`GOPRIVATE` for private modules and use a read-only credential for them in
this trusted job. Provide the credential using the
repository's approved secret mechanism and avoid persisting it beyond the job.
Fetch full history and tags, as above: the recipe computes a version from tags
and otherwise falls back to `v0.0.0`. Pin the build tools before enabling this
workflow. Run the build before Google auth
because it can outlast federated credentials; job OIDC is still available to
all steps, so the trust gate must run before the job starts.

## Build and push with caller authentication

Use the `build` and `push` entries in one trusted job. Set
`VERIFIER_IMAGE_REPOSITORY` to the private Artifact Registry Docker image
path without a tag or digest. Pass that path and the same commit SHA to both
entries. The push entry exposes the published reference as
`steps.image.outputs.image`.

The caller job owns Google Cloud authentication and Docker access. If using
WIF, grant that job `id-token: write` and keep the project and identity inputs in
the caller's variables. Authenticate, set up the Cloud SDK, and configure
Docker for the registry host between build and push. Use an identity with
write access to the private repository only. When using the combined entry
point, configure Docker access before calling it.

## Deployment handoff

The consumer must use one tenant-wide concurrency group from wake through
verification and cleanup. Compare non-UI changes against the deployed revision;
use the `loft` deployment, local port 8080 and the verify CLI with its own stub
server. Run the verifier in the planned self-hosted loft.rocks environment.

Before implementation, confirm the permanent project, tenant, host cluster,
tenant-scoped CI identity and secret reference; CLI login, wake and connect
commands, kube context, awake condition, timeout and idle policy. Confirm the
namespace, deployment container, Helm release and values or patch owner, Service
and target port, image architecture, revision annotation and bootstrap value,
Git history and missing-commit behavior. Record the pushed digest and source SHA,
roll out that digest, verify the running image, then update the revision. Define
cancellation, rollout and API readiness checks, port-forward placement and cleanup
on success, failure and cancellation. Time a sleeping UI-only run and a backend
change including a real node pull. Earlier copy-based proof timings do not measure
the CI image path. A push alone does not prove tenant pull or acceptance.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED | DEFAULT |                               DESCRIPTION                                |
|------------------|--------|----------|---------|--------------------------------------------------------------------------|
|     head-sha     | string |   true   |         |              Full commit SHA of the checked-out <br>source               |
| image-repository | string |   true   |         | Private Artifact Registry Docker image path <br>without a tag or digest  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

| OUTPUT |  TYPE  |        DESCRIPTION        |
|--------|--------|---------------------------|
| image  | string | Published image reference |

<!-- AUTO-DOC-OUTPUT:END -->

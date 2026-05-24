# Pre-Release Setup

Shared setup for the `loft-sh/loft-enterprise` pre-release workflow
(`.github/workflows/prerelease-checks.yaml`). Replaces ~100 lines of
duplicated setup steps that lived inline in both the `prerelease-vcluster`
and `prerelease-aicloud` jobs.

The action performs, in order:

1. Free disk space (`jlumbroso/free-disk-space@v1.3.1`).
2. Checkout the calling repo (`actions/checkout@v6`).
3. Install Go (`actions/setup-go@v5`, `go-version-file: go.mod`, cache on).
4. Install `kubectl` (`azure/setup-kubectl@v4`).
5. Install `helm` (`azure/setup-helm@v4`).
6. AWS Login via OIDC (`aws-actions/configure-aws-credentials@v5.1.1`,
   `role-to-assume: arn:aws:iam::084374023943:role/e2e-test-executor`,
   `aws-region: us-west-2`, `role-duration-seconds: 6300`,
   `output-credentials: true`).
7. Resolve and validate the four version inputs (see below).
8. Download the `vcluster` CLI binary that matches the resolved base
   standalone vCluster version.
9. Verify `kubectl`, `helm`, and `vcluster` are on `$PATH`.

The action is intended for the two pre-release jobs only. AI Cloud's EC2
provisioning (`aws-test-infra`) and the Ginkgo test execution
(`run-ginkgo`) remain in the calling workflow.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|                INPUT                |  TYPE  | REQUIRED | DEFAULT |                                                                        DESCRIPTION                                                                        |
|-------------------------------------|--------|----------|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
|        platform-base-version        | string |  false   |         | Platform version for the initial install <br>(e.g. 4.9.0). Empty leaves the output empty; <br>the consumer wires its own default <br>into the test step.  |
|         platform-rc-version         | string |  false   |         |           Platform RC version for upgrade (e.g. 4.10.0-alpha.6). <br>Empty resolves to the latest pre-release <br>of loft-sh/loft-enterprise.             |
|          role-session-name          | string |   true   |         |        AWS STS role-session-name. Each consumer job <br>passes a distinct value (e.g. prerelease-vcluster-<run-id>, prerelease-aicloud-<run-id>).         |
| standalone-vcluster-upgrade-version | string |   true   |         |                   vCluster version to upgrade standalone to <br>(e.g. 0.35.0-alpha.7). Must differ from the resolved <br>base version.                    |
|     standalone-vcluster-version     | string |  false   |         |            vCluster version to install for standalone <br>(e.g. 0.34.0). Empty resolves to the latest <br>GitHub release of loft-sh/vcluster.             |

<!-- AUTO-DOC-INPUT:END -->

Inputs accept versions with or without a leading `v`; the action strips
the `v` before validating against the semver regex
`^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$`.

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|               OUTPUT                |  TYPE  |                                     DESCRIPTION                                      |
|-------------------------------------|--------|--------------------------------------------------------------------------------------|
|        platform-base-version        | string | Validated platform base version (no leading v). Empty <br>when the input was empty.  |
|         platform-rc-version         | string |                    Resolved platform RC version (no leading v).                      |
| standalone-vcluster-upgrade-version | string |            Validated standalone vCluster upgrade version (no leading v).             |
|     standalone-vcluster-version     | string |                Resolved standalone vCluster version (no leading v).                  |

<!-- AUTO-DOC-OUTPUT:END -->

Outputs are written to `$GITHUB_OUTPUT` only. The consumer wires them to
its downstream test step via an `env:` block (see Usage below). This
matches the convention of `aws-test-infra` and avoids the
`github-env` zizmor finding that comes with mirroring values into
`$GITHUB_ENV` from a composite step.

The OIDC step exports `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
`AWS_SESSION_TOKEN` to the environment via
`aws-actions/configure-aws-credentials` with `output-credentials: true`.
These propagate to subsequent steps in the calling job through the
standard action mechanism, so the consumer does not need to wire them
explicitly.

## Permissions

The calling job must declare:

```yaml
permissions:
  contents: read
  id-token: write
```

`id-token: write` is required for the OIDC `assume-role` exchange.

## Usage

```yaml
jobs:
  prerelease-vcluster:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    permissions:
      contents: read
      id-token: write
    env:
      STANDALONE_VCLUSTER_UPGRADE_VERSION: ${{ inputs.standalone_vcluster_upgrade_version || github.event.client_payload.standalone_vcluster_upgrade_version }}
      PLATFORM_BASE_VERSION: ${{ inputs.platform_base_version || github.event.client_payload.platform_base_version }}
      PLATFORM_RC_VERSION:   ${{ inputs.platform_rc_version   || github.event.client_payload.platform_rc_version }}
    steps:
      - name: Pre-release setup
        id: setup
        uses: loft-sh/github-actions/.github/actions/prerelease-setup@prerelease-setup/v1
        with:
          role-session-name: prerelease-vcluster-${{ github.run_id }}
          standalone-vcluster-version: ${{ inputs.standalone_vcluster_version || github.event.client_payload.standalone_vcluster_version }}
          standalone-vcluster-upgrade-version: ${{ env.STANDALONE_VCLUSTER_UPGRADE_VERSION }}
          platform-base-version: ${{ env.PLATFORM_BASE_VERSION }}
          platform-rc-version: ${{ env.PLATFORM_RC_VERSION }}

      - name: Run pre-release vCluster checks
        uses: loft-sh/github-actions/.github/actions/run-ginkgo@run-ginkgo/v1
        with:
          test-dir: e2e/prerelease/vcluster
          ginkgo-label: prerelease-upgrade
          timeout: 80m
          procs: "1"
          additional-ginkgo-flags: "-v"
        env:
          STANDALONE_VCLUSTER_VERSION:         ${{ steps.setup.outputs.standalone-vcluster-version }}
          DEFAULT_VCLUSTER_CHART_VERSION:      ${{ steps.setup.outputs.standalone-vcluster-version }}
          STANDALONE_VCLUSTER_UPGRADE_VERSION: ${{ steps.setup.outputs.standalone-vcluster-upgrade-version }}
          PLATFORM_BASE_VERSION:               ${{ steps.setup.outputs.platform-base-version }}
          PLATFORM_RC_VERSION:                 ${{ steps.setup.outputs.platform-rc-version }}
          AWS_ACCESS_KEY_ID:     ${{ env.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ env.AWS_SECRET_ACCESS_KEY }}
          AWS_SESSION_TOKEN:     ${{ env.AWS_SESSION_TOKEN }}
```

The AI Cloud job is identical apart from a different `role-session-name`,
the addition of `VCI_K8S_VERSION` / `VCI_K8S_UPGRADE_VERSION` (kept at
the workflow `env:` block in the consumer, not passed through this
action), and the surrounding `aws-test-infra` provision/cleanup steps
that are specific to that job.

## Notes

- The two `vci-k8s-*` inputs called out in the original ticket scope are
  intentionally not part of this action. They are not produced or
  validated by any of the setup steps, and they are already available to
  the consumer at the workflow `env:` level. Adding them as
  pass-through-only inputs would be dead code.

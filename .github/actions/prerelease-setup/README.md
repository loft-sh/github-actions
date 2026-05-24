# Pre-Release Setup

Shared setup for the `loft-sh/loft-enterprise` pre-release workflow
(`.github/workflows/prerelease-checks.yaml`). Replaces ~100 lines of
duplicated setup steps that lived inline in both the `prerelease-vcluster`
and `prerelease-aicloud` jobs.

The action performs, in order:

1. Free disk space (`jlumbroso/free-disk-space@v1.3.1`).
2. Checkout the calling repo.
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

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `role-session-name` | yes | — | AWS STS role-session-name. Pass a job-distinct value such as `prerelease-vcluster-${{ github.run_id }}`. |
| `standalone-vcluster-version` | no | `''` | Standalone vCluster install version (e.g. `0.34.0`). Empty resolves to the latest GitHub release of `loft-sh/vcluster`. |
| `standalone-vcluster-upgrade-version` | yes | — | Standalone vCluster upgrade target (e.g. `0.35.0-alpha.7`). Must differ from the resolved base. |
| `platform-base-version` | no | `''` | Platform install version (e.g. `4.9.0`). Empty leaves `PLATFORM_BASE_VERSION` unset; the consumer test step uses its own default. |
| `platform-rc-version` | no | `''` | Platform RC upgrade version (e.g. `4.10.0-alpha.6`). Empty resolves to the latest pre-release of `loft-sh/loft-enterprise`. |
| `vci-k8s-version` | no | `''` | Pass-through for the private-nodes VCI Kubernetes version (v-prefixed, e.g. `v1.34.5`). Forwarded to `$GITHUB_ENV` as `VCI_K8S_VERSION`. |
| `vci-k8s-upgrade-version` | no | `''` | Pass-through for the VCI K8s upgrade target (v-prefixed). Forwarded to `$GITHUB_ENV` as `VCI_K8S_UPGRADE_VERSION`. |

Inputs accept versions with or without a leading `v`; the action strips
the `v` before validating against the semver regex
`^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$`.

## Outputs

| Name | Description |
|------|-------------|
| `standalone-vcluster-version` | Resolved standalone vCluster version (no leading `v`). |
| `standalone-vcluster-upgrade-version` | Validated upgrade version (no leading `v`). |
| `platform-base-version` | Validated platform base version (no leading `v`). Empty when the input was empty. |
| `platform-rc-version` | Resolved platform RC version (no leading `v`). |

## Environment variables exported to subsequent steps

The action also writes the resolved values to `$GITHUB_ENV` so the
calling job's downstream steps (in particular `run-ginkgo`) read them
as plain env vars, matching the behaviour of the inlined version:

- `STANDALONE_VCLUSTER_VERSION`
- `DEFAULT_VCLUSTER_CHART_VERSION` (same value as
  `STANDALONE_VCLUSTER_VERSION`; consumed by some test paths)
- `STANDALONE_VCLUSTER_UPGRADE_VERSION`
- `PLATFORM_RC_VERSION`
- `PLATFORM_BASE_VERSION` (only when `platform-base-version` was provided)
- `VCI_K8S_VERSION` (only when `vci-k8s-version` was provided)
- `VCI_K8S_UPGRADE_VERSION` (only when `vci-k8s-upgrade-version` was provided)

The OIDC step exports `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and
`AWS_SESSION_TOKEN` to the environment via
`aws-actions/configure-aws-credentials` with `output-credentials: true`.

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
```

The AI Cloud job is identical apart from a different `role-session-name`,
the addition of `vci-k8s-version` / `vci-k8s-upgrade-version` inputs, and
the surrounding `aws-test-infra` provision/cleanup steps that are
specific to that job.

# CI Test Notification

Generic Slack notification action for CI test results. Covers nightly E2E, conformance, and other automated test suites.

Replaces the nightly-specific `ci-notify-nightly-tests` action with a generic interface: the caller provides a test name, status, and optional details markdown — the action builds the Block Kit message and sends it.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `test-name` | Test suite name for the header (e.g. "E2E Ginkgo Nightly Tests"). Keep under ~130 chars (Slack header limit is 150 chars; status suffix uses ~15). | yes | |
| `status` | Test status: `success`, `failure`, `cancelled`, or `skipped` | yes | |
| `details` | Markdown text appended after the build URL | no | `''` |
| `webhook-url` | Slack incoming webhook URL | yes | |

## Message format

```
[emoji] [test-name] [status]
─────────────────────────────
Build URL: <link to workflow run>

<details if provided>
─────────────────────────────
<repo> · Run #<number>
```

## Usage

### Nightly E2E tests

```yaml
- uses: loft-sh/github-actions/.github/actions/ci-test-notify@ci-test-notify/v1
  with:
    test-name: E2E Ginkgo Nightly Tests
    status: ${{ needs.e2e-tests.result }}
    details: "E2E Tests: ${{ needs.e2e-tests.result }}"
    webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

### Conformance tests (with extra fields)

```yaml
- uses: loft-sh/github-actions/.github/actions/ci-test-notify@ci-test-notify/v1
  with:
    # Keep test-name under ~130 chars (Slack header block limit is 150)
    test-name: "vCluster Conformance Tests (${{ inputs.sonobuoy_mode }})"
    status: ${{ steps.status.outputs.status }}
    details: |
      *vCluster CLI:* `${{ steps.version.outputs.ref }}`
      *vCluster PRO:* `${{ inputs.base_ref }}`

      Sonobuoy results: ${{ steps.upload.outputs.artifact-url }}
    webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

### Failure-only with summary

```yaml
- uses: loft-sh/github-actions/.github/actions/ci-test-notify@ci-test-notify/v1
  if: needs.e2e-tests.result == 'failure'
  with:
    test-name: E2E Ginkgo Nightly Tests
    status: failure
    details: |
      E2E Tests: failure

      ${{ needs.e2e-tests.outputs.failure-summary || 'Check build logs for details.' }}
    webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_DEV_VCLUSTER }}
```

## Permissions

No special GitHub permissions required. The `webhook-url` must be supplied via a repository secret.

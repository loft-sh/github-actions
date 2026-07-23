# CI Test Notification

Generic Slack notification action for CI test results. Covers nightly E2E, conformance, and other automated test suites.

Replaces the nightly-specific `ci-notify-nightly-tests` action with a generic interface: the caller provides a test name, status, and optional details markdown — the action builds the Block Kit message and sends it.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT    |  TYPE  | REQUIRED | DEFAULT |                                                                                                                                            DESCRIPTION                                                                                                                                             |
|-------------|--------|----------|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   details   | string |  false   |         |                                                                                                   Markdown text appended after the build <br>URL (test results, versions, artifact links, etc.)                                                                                                    |
|   status    | string |   true   |         | Run status, typically `needs.<job>.result` or `job.status`. <br>`success` and `failure` notify; `cancelled` and <br>`skipped` are treated as no-ops and <br>send nothing. Use `info` for a <br>standalone informational notice (e.g. a deploy) that always <br>notifies with no pass/fail suffix.  |
|  test-name  | string |   true   |         |                                                    Test suite name for the header <br>(e.g. "E2E Ginkgo Nightly Tests"). Keep under ~130 chars — <br>Slack header blocks have a 150-char <br>limit and the status suffix takes <br>~15 chars.                                                      |
| webhook-url | string |   true   |         |                                                                                                                                     Slack incoming webhook URL                                                                                                                                     |

<!-- AUTO-DOC-INPUT:END -->

## Message format

```
[emoji] [test-name] [status]
─────────────────────────────
Build URL: <link to workflow run>

<details if provided>
─────────────────────────────
<repo> · Run #<number>
```

`status: info` renders a 🚀 header with no `[status]` suffix, for informational
notices (e.g. a deploy) rather than pass/fail results.

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

### Informational deploy notice

`info` always notifies (no pass/fail suffix) and uses a 🚀 header, for a
standalone notice such as a release candidate landing in staging:

```yaml
- uses: loft-sh/github-actions/.github/actions/ci-test-notify@ci-test-notify/v1
  with:
    test-name: Release candidate deployed to staging.vcluster.cloud
    status: info
    details: |
      • vcluster-platform: `4.10.0-rc.1`

      QA: spin up an instance on staging, verify it's healthy, then tick the
      pre-release checklist.
    webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_QA }}
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

## Notification gating

The action only notifies on actionable outcomes. A `status` of `cancelled` or
`skipped` is treated as a no-op: the action logs a notice and sends nothing.
This means callers can pass `needs.<job>.result` or `job.status` straight
through without a guard. A cancelled run (aborted by a human or superseded) or a
skipped job never produces a Slack alert; only `success` and `failure` do.

An empty `webhook-url` (fork PRs, where secrets are unavailable) also suppresses
the notification.

## Permissions

No special GitHub permissions required. The `webhook-url` must be supplied via a repository secret.

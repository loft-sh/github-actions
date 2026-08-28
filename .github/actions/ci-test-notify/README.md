# CI Test Notification

Generic Slack notification action for CI test results. Covers nightly E2E, conformance, and other automated test suites.

Replaces the nightly-specific `ci-notify-nightly-tests` action with a generic interface: the caller provides a test name, status, and optional details markdown — the action builds the Block Kit message and sends it.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT       |  TYPE  | REQUIRED | DEFAULT |                                                                                                                                                                            DESCRIPTION                                                                                                                                                                            |
|-------------------|--------|----------|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|      details      | string |  false   |         |                                                                                                                                  Markdown text appended after the build <br>URL (test results, versions, artifact links, etc.)                                                                                                                                    |
| run-link-position | string |  false   | `"top"` | Where the immutable workflow-run link goes, <br>and how it reads. `top` (default) <br>puts a bare `Build URL: <url>` line above <br>`details`, unchanged from before this input <br>existed. `bottom` puts a linked `Workflow: View workflow run` <br>line below `details`, so the content <br>leads and the link trails. Invalid <br>values fall back to `top`.  |
|      status       | string |   true   |         |                                                                                      Run status, typically `needs.<job>.result` or `job.status`. <br>`success`, `failure`, and `warning` notify; `cancelled` <br>and `skipped` are treated as no-ops <br>and send nothing.                                                                                        |
|     test-name     | string |   true   |         |                                                                                    Test suite name for the header <br>(e.g. "E2E Ginkgo Nightly Tests"). Keep under ~130 chars — <br>Slack header blocks have a 150-char <br>limit and the status suffix takes <br>~15 chars.                                                                                     |
|    webhook-url    | string |   true   |         |                                                                                                                                                                    Slack incoming webhook URL                                                                                                                                                                     |

<!-- AUTO-DOC-INPUT:END -->

## Message format

With `run-link-position: top` (the default), unchanged from before that input existed:

```
[emoji] [test-name] [status]
─────────────────────────────
Build URL: <link to workflow run>

<details if provided>
─────────────────────────────
<repo> · Run #<number>
```

With `run-link-position: bottom`, for messages whose `details` are the point and
should be read first:

```
[emoji] [test-name] [status]
─────────────────────────────
<details if provided>

Workflow: View workflow run
─────────────────────────────
<repo> · Run #<number>
```

The link is not merely moved: `top` prints the bare URL after `Build URL:`, while
`bottom` renders a linked label. `top` is left exactly as it was so that switching
position is opt-in for the roughly thirty existing call sites.

The section is capped at Slack's 3000-character limit and the header at 150. Both
are measured in characters rather than bytes, so multi-byte text is not truncated
early or cut mid-character; with `bottom`, the run link is always preserved and the
`details` are what give way.

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
    webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

## Notification gating

The action only notifies on actionable outcomes. A `status` of `cancelled` or
`skipped` is treated as a no-op: the action logs a notice and sends nothing.
This means callers can pass `needs.<job>.result` or `job.status` straight
through without a guard. A cancelled run (aborted by a human or superseded) or a
skipped job never produces a Slack alert.

Everything else notifies. `success` and `failure` are the usual pair; `warning`
is for an advisory result that is worth reporting but is not a failure, such as a
CVE scan running on the default non-blocking posture. An unrecognised status also
notifies, under a `❓ Unknown (<status>)` header, on the grounds that a status
nobody anticipated is more useful surfaced than swallowed.

An empty `webhook-url` (fork PRs, where secrets are unavailable) also suppresses
the notification.

## Permissions

No special GitHub permissions required. The `webhook-url` must be supplied via a repository secret.

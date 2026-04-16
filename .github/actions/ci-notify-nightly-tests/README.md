# Slack Nightly E2E Test Notification

Sends a Slack notification with E2E nightly test results, including a summary, run details, and links back to the workflow run.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT     |  TYPE  | REQUIRED | DEFAULT |               DESCRIPTION               |
|--------------|--------|----------|---------|-----------------------------------------|
| failed_tests | string |   true   |         | List of failed test suites, if <br>any  |
|    run_id    | string |   true   |         |          GitHub Actions run ID          |
|  run_number  | string |   true   |         |        GitHub Actions run number        |
| source_repo  | string |   true   |         |            Source repository            |
|    status    | string |   true   |         |     Test status (success, failure)      |
| test_results | string |   true   |         |          Test results summary           |
| webhook_url  | string |   true   |         |            Slack Webhook URL            |

<!-- AUTO-DOC-INPUT:END -->

## Usage

```yaml
jobs:
  notify:
    runs-on: ubuntu-latest
    needs: e2e
    if: always()
    steps:
      - uses: loft-sh/github-actions/.github/actions/ci-notify-nightly-tests@main
        with:
          test_results: ${{ needs.e2e.outputs.summary }}
          run_id: ${{ github.run_id }}
          run_number: ${{ github.run_number }}
          status: ${{ needs.e2e.result }}
          source_repo: ${{ github.repository }}
          failed_tests: ${{ needs.e2e.outputs.failed_tests }}
          webhook_url: ${{ secrets.SLACK_NIGHTLY_WEBHOOK_URL }}
```

## Permissions

This action requires no special GitHub permissions. The `webhook_url` must be supplied via a secret.

| Secret | Description |
|--------|-------------|
| `SLACK_NIGHTLY_WEBHOOK_URL` | Incoming webhook URL for the target Slack channel |

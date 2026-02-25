# Slack Nightly E2E Test Notification

Sends a Slack notification with E2E nightly test results, including a summary, run details, and links back to the workflow run.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `test_results` | Test results summary text | yes | |
| `run_id` | GitHub Actions run ID | yes | |
| `run_number` | GitHub Actions run number | yes | |
| `status` | Test status: `success` or `failure` | yes | |
| `source_repo` | Source repository (e.g. `loft-sh/vcluster`) | yes | |
| `failed_tests` | List of failed test suites, if any | yes | `''` |
| `webhook_url` | Slack incoming webhook URL | yes | |

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

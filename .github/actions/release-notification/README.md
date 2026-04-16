# Slack Release Notification

Sends a Slack notification when a new release is published.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT     |  TYPE  | REQUIRED |           DEFAULT            |                                           DESCRIPTION                                           |
|---------------|--------|----------|------------------------------|-------------------------------------------------------------------------------------------------|
|  base_branch  | string |  false   |                              | Source branch from which the release <br>was cut (auto-detected from git history when omitted)  |
|    changes    | string |  false   | `"See changelog link below"` |                                         Release changes                                         |
|   is_draft    | string |  false   |          `"false"`           |                                    Is this a draft release?                                     |
| is_prerelease | string |  false   |          `"false"`           |                                     Is this a pre-release?                                      |
| previous_tag  | string |  false   |                              |                          Previous release tag for changelog comparison                          |
|    product    | string |   true   |                              |                          Product name (vCluster or vCluster Platform)                           |
|    status     | string |  false   |         `"success"`          |                  Release status: success, failure, cancelled, or <br>skipped                    |
|  target_repo  | string |   true   |                              |                                        Target repository                                        |
|    version    | string |   true   |                              |                                         Release version                                         |
|  webhook_url  | string |   true   |                              |                                        Slack Webhook URL                                        |

<!-- AUTO-DOC-INPUT:END -->

## Usage

```yaml
jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - uses: loft-sh/github-actions/.github/actions/release-notification@main
        with:
          version: ${{ github.ref_name }}
          target_repo: ${{ github.repository }}
          product: vCluster
          webhook_url: ${{ secrets.SLACK_RELEASE_WEBHOOK_URL }}
```

With changelog link:

```yaml
      - uses: loft-sh/github-actions/.github/actions/release-notification@main
        with:
          version: ${{ github.ref_name }}
          previous_tag: ${{ steps.prev.outputs.tag }}
          target_repo: ${{ github.repository }}
          product: vCluster Platform
          base_branch: ${{ github.ref_name }}
          webhook_url: ${{ secrets.SLACK_RELEASE_WEBHOOK_URL }}
```

## Permissions

This action requires no special GitHub permissions. The `webhook_url` must be supplied via a secret.

| Secret | Description |
|--------|-------------|
| `SLACK_RELEASE_WEBHOOK_URL` | Incoming webhook URL for the target Slack channel |

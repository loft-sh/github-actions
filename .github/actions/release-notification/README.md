# Slack Release Notification

Sends a Slack notification when a new release is published.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `version` | Release version | yes | |
| `previous_tag` | Previous release tag for changelog comparison | no | `''` |
| `changes` | Release changes | no | `'See changelog link below'` |
| `is_draft` | Is this a draft release? | no | `'false'` |
| `is_prerelease` | Is this a pre-release? | no | `'false'` |
| `target_repo` | Target repository (e.g. `loft-sh/vcluster`) | yes | |
| `product` | Product name (e.g. `vCluster` or `vCluster Platform`) | yes | |
| `base_branch` | Source branch from which the release was cut | no | |
| `webhook_url` | Slack incoming webhook URL | yes | |

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

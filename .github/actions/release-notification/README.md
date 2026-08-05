# Slack Release Notification

Sends a Slack notification when a new release is published.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED |           DEFAULT            |                                                                                                        DESCRIPTION                                                                                                        |
|------------------|--------|----------|------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   base_branch    | string |  false   |                              |                                                              Source branch from which the release <br>was cut (auto-detected from git history when omitted)                                                               |
|     changes      | string |  false   | `"See changelog link below"` |                                                                                                      Release changes                                                                                                      |
|     is_draft     | string |  false   |          `"false"`           |                                                                                                 Is this a draft release?                                                                                                  |
|  is_prerelease   | string |  false   |          `"false"`           |                                                                          Whether to show the release as <br>a GitHub pre-release in the banner.                                                                           |
| needs_promotion  | string |  false   |          `"false"`           |                                                                       Whether to show a GitHub promotion <br>reminder linking to promote_workflow.                                                                        |
|   paired_repo    | string |  false   |                              |                                                                   Optional second repository whose release and <br>changelog are linked in the banner.                                                                    |
|   previous_tag   | string |  false   |                              |                                                                                       Previous release tag for changelog comparison                                                                                       |
|     product      | string |   true   |                              |                                                                                       Product name (vCluster or vCluster Platform)                                                                                        |
| promote_workflow | string |  false   |   `"promote-release.yaml"`   |                                                 Workflow file in target_repo that performs <br>the promotion. Linked from the banner <br>when needs_promotion is "true".                                                  |
|      status      | string |  false   |         `"success"`          |                                                                               Release status: success, failure, cancelled, or <br>skipped                                                                                 |
|   target_repo    | string |   true   |                              |                                                                                                     Target repository                                                                                                     |
|   triggered_by   | string |  false   |   `"${{ github.actor }}"`    | Who triggered the release (shown in the Slack banner). Defaults <br>to github.actor; callers that dispatch the <br>release via a bot PAT should <br>pass the human actor so the <br>banner does not read as the <br>bot.  |
|     version      | string |   true   |                              |                                                                                                      Release version                                                                                                      |
|   webhook_url    | string |   true   |                              |                                                                                                     Slack Webhook URL                                                                                                     |

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

### GitHub label and paired release links

`is_prerelease: "true"` adds a `GitHub label: Pre-release` field.
`needs_promotion: "true"` instead shows the GitHub `None` label and links to
`promote_workflow`, telling the Release Captain that the release still needs to
be promoted. With neither flag set, no label field is rendered, so existing
callers that publish directly to Latest keep their previous banner.

Set `paired_repo` when one cut publishes the same version in two repositories,
such as a private product repository and its public OSS repository. The banner
then links both repositories' changelogs and releases, with each link labelled
by its repository name. Leave it empty for a single-repository release.

## Permissions

This action requires no special GitHub permissions. The `webhook_url` must be supplied via a secret.

| Secret | Description |
|--------|-------------|
| `SLACK_RELEASE_WEBHOOK_URL` | Incoming webhook URL for the target Slack channel |

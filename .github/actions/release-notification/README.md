# Slack Release Notification

Sends a Slack notification when a new release is published.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED |           DEFAULT            |                                                                                                                                                                                                                            DESCRIPTION                                                                                                                                                                                                                             |
|------------------|--------|----------|------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   base_branch    | string |  false   |                              |                                                                                                                                                                                  Source branch from which the release <br>was cut (auto-detected from git history when omitted)                                                                                                                                                                                    |
|     changes      | string |  false   | `"See changelog link below"` |                                                                                                                                                                                                                          Release changes                                                                                                                                                                                                                           |
|     is_draft     | string |  false   |          `"false"`           |                                                                                                                                                                                                                      Is this a draft release?                                                                                                                                                                                                                      |
|  is_prerelease   | string |  false   |          `"false"`           |                                                                                                                                                                                                                       Is this a pre-release?                                                                                                                                                                                                                       |
| needs_promotion  | string |  false   |          `"false"`           |                     Set to "true" when the release <br>is published un-promoted and a human <br>still has to promote it (the GitHub "None" label: not a pre-release, not Latest). <br>Adds a line to the banner <br>pointing at the promote workflow, since <br>the release build is the only <br>thing that tells the Release Captain <br>a step is left. Opt-in, so <br>products whose releases ship straight to <br>Latest are unaffected.                      |
|   paired_repo    | string |  false   |                              | Second repository that publishes the same <br>version, e.g. the public OSS repo <br>alongside a private product repo. When <br>set, the banner links the release <br>and the changelog for BOTH repos <br>instead of target_repo only - a <br>single link is wrong for a <br>product whose cut produces two releases, <br>and the private one is the <br>less useful of the two for <br>most readers. Leave empty for products <br>that publish a single release.  |
|   previous_tag   | string |  false   |                              |                                                                                                                                                                                                           Previous release tag for changelog comparison                                                                                                                                                                                                            |
|     product      | string |   true   |                              |                                                                                                                                                                                                            Product name (vCluster or vCluster Platform)                                                                                                                                                                                                            |
| promote_workflow | string |  false   |   `"promote-release.yaml"`   |                                                                                                                                                                     Workflow file in target_repo that performs <br>the promotion. Linked from the banner <br>when needs_promotion is "true".                                                                                                                                                                       |
|      status      | string |  false   |         `"success"`          |                                                                                                                                                                                                    Release status: success, failure, cancelled, or <br>skipped                                                                                                                                                                                                     |
|   target_repo    | string |   true   |                              |                                                                                                                                                                                                                         Target repository                                                                                                                                                                                                                          |
|   triggered_by   | string |  false   |   `"${{ github.actor }}"`    |                                                                                                                     Who triggered the release (shown in the Slack banner). Defaults <br>to github.actor; callers that dispatch the <br>release via a bot PAT should <br>pass the human actor so the <br>banner does not read as the <br>bot.                                                                                                                       |
|     version      | string |   true   |                              |                                                                                                                                                                                                                          Release version                                                                                                                                                                                                                           |
|   webhook_url    | string |   true   |                              |                                                                                                                                                                                                                         Slack Webhook URL                                                                                                                                                                                                                          |

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

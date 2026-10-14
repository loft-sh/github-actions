# Slack Release Notification

Sends a Slack notification when a new release is published.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED |           DEFAULT            |                                                                                                          DESCRIPTION                                                                                                           |
|------------------|--------|----------|------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   base_branch    | string |  false   |                              |                                                                Source branch from which the release <br>was cut (auto-detected from git history when omitted)                                                                  |
|     changes      | string |  false   | `"See changelog link below"` |                                                                                                        Release changes                                                                                                         |
|     dry-run      | string |  false   |          `"false"`           |                                                           Resolve and expose banner text without <br>posting to Slack. Intended for validation <br>and smoke tests.                                                            |
|     is_draft     | string |  false   |          `"false"`           |                                                                                                    Is this a draft release?                                                                                                    |
|  is_prerelease   | string |  false   |          `"false"`           |                                                                            Whether to show the release as <br>a GitHub pre-release in the banner.                                                                              |
| needs_promotion  | string |  false   |          `"false"`           |                                                                         Whether to show a GitHub promotion <br>reminder linking to promote_workflow.                                                                           |
|   paired_repo    | string |  false   |                              |                                                                     Optional second repository whose release and <br>changelog are linked in the banner.                                                                       |
|   previous_tag   | string |  false   |                              |                                                                                         Previous release tag for changelog comparison                                                                                          |
|     product      | string |   true   |                              |                                                                                          Product name (vCluster or vCluster Platform)                                                                                          |
| promote_workflow | string |  false   |   `"promote-release.yaml"`   |                                                   Workflow file in target_repo that performs <br>the promotion. Linked from the banner <br>when needs_promotion is "true".                                                     |
| slack_bot_token  | string |  false   |                              |         Slack bot token with chat:write in <br>slack_channel_id. When set with slack_channel_id, the <br>success banner is posted through chat.postMessage <br>and its message ts is exposed <br>for thread replies.           |
| slack_channel_id | string |  false   |                              |                                                                                         Slack channel id for the bot <br>token post.                                                                                           |
|      status      | string |  false   |         `"success"`          |                                                                                  Release status: success, failure, cancelled, or <br>skipped                                                                                   |
|   target_repo    | string |   true   |                              |                                                                                                       Target repository                                                                                                        |
|   triggered_by   | string |  false   |   `"${{ github.actor }}"`    |   Who triggered the release (shown in the Slack banner). Defaults <br>to github.actor; callers that dispatch the <br>release via a bot PAT should <br>pass the human actor so the <br>banner does not read as the <br>bot.     |
|     version      | string |   true   |                              |                                                                                                        Release version                                                                                                         |
|   webhook_url    | string |  false   |                              | Slack incoming webhook URL. Required for <br>failure notifications, and for success banners <br>unless slack_bot_token and slack_channel_id are set. <br>With a bot token it is <br>the fallback when the bot post <br>fails.  |

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

### Bot token banner and thread replies

An incoming webhook returns no message ts, so nothing can reply in the
banner's thread. Pass `slack_bot_token` and `slack_channel_id` to post the
success banner through `chat.postMessage` instead; the `message_ts` and
`channel_id` outputs then identify it, and
[`release-summary`](../release-summary/README.md) replies under it. The bot
needs `chat:write`, `channels:history` (`groups:history` for a private
channel) and membership in the channel.

The bot post never resends: a retry after a timeout or a 5xx can duplicate a
banner that already landed. `banner-result.py` then settles the outcome:

| Bot post outcome | Banner | Webhook fallback |
|---|---|---|
| ok | posted, `message_ts` set | no |
| rejected by Slack (`not_in_channel`, `invalid_auth`, `missing_scope`, `ratelimited`, ...) | not posted | yes, with a warning naming the remedy |
| ambiguous (timeout, 5xx, `internal_error`, no response), banner found in the channel | posted, `message_ts` set | no |
| ambiguous, banner not in the channel | not posted | yes, with a warning |
| ambiguous, channel unreadable | unknown | yes, with a warning that it may duplicate |

The banner carries `release_banner` message metadata (repository and
version), which is how the channel read recognizes it. Without `webhook_url`
a banner that did not post fails the step. After a webhook post
`message_ts` stays empty and the summary skips. Failure notifications always
post through `webhook_url`, so a dry run fails without it.

```yaml
      - id: banner
        uses: loft-sh/github-actions/.github/actions/release-notification@release-notification/v3
        with:
          version: ${{ github.ref_name }}
          target_repo: ${{ github.repository }}
          product: vCluster Platform
          slack_bot_token: ${{ secrets.SLACK_BOT_TOKEN_PRODUCT_RELEASES }}
          slack_channel_id: C068ZLG3QJY
          webhook_url: ${{ secrets.SLACK_WEBHOOK_URL_PRODUCT_RELEASES }}
```

## Permissions

This action requires no special GitHub permissions. Supply `webhook_url` and `slack_bot_token` through secrets.

| Secret | Description |
|--------|-------------|
| `SLACK_RELEASE_WEBHOOK_URL` | Incoming webhook URL for the target Slack channel |
| `SLACK_BOT_TOKEN_PRODUCT_RELEASES` | Optional bot token with `chat:write` and `channels:history` for the bot token banner post |

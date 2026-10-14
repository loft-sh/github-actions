# Release summary

Posts an AI summary of what a release changed since the previous tag, as a
Slack thread reply under the release banner in #product-releases. The banner
keeps its changelog link against the latest stable release; the thread
answers what this tag itself changed.

The action is advisory. Every failure path, from a missing secret to a
provider outage or a Slack rejection, ends in a warning and exit code 0, and
every step continues on error, so it can never fail the release that calls
it. Give the calling job `continue-on-error: true` as well and keep it out of
any failure-notification job's `needs`.

## How it works

1. `src/collect.py` picks the comparison base (the nearest earlier `v*` tag
   that is not a `-next` tag, or `previous-tag`), lists first-parent commits,
   and resolves each to its merged PR through GraphQL
   `associatedPullRequests`. Rebase-merged PRs carry no `(#N)` in their
   subjects, so the subject is only a fallback. It extracts Linear ids from
   closing keywords, Linear links, title prefixes and branch names.
2. [`ai-step`](../ai-step/README.md) summarizes the PR descriptions, changed
   paths and diffstat into features, bug fixes, tech debt and tests, ordered
   by customer impact. The input travels through `input-file`, because PR
   descriptions for one alpha already approach the 128 KiB env var limit.
3. `src/render.py` builds the Slack blocks. PR and Linear links come only from
   the collected data: a PR number the model invents is dropped, and Linear
   ids in the model's text are never linked.
4. `slackapi/slack-github-action` posts the reply with `thread_ts` set to the
   banner's `ts`.
5. `src/conclude.sh` reports `posted`, `dry-run`, `skipped` or `failed` with a
   reason that names the remedy, and writes counts to the job summary.

The banner must be posted with a bot token to have a `ts`: see the
`slack_bot_token` input of [`release-notification`](../release-notification/README.md)
and the `message_ts` output of `notify-release.yaml`.

## Usage

```yaml
  notify_release:
    uses: loft-sh/github-actions/.github/workflows/notify-release.yaml@release-notification/v3
    with:
      release_version: ${{ needs.get_version.outputs.version }}
      target_repo: loft-sh/loft-enterprise
      product: vCluster Platform
      slack_channel_id: C068ZLG3QJY
    secrets:
      SLACK_WEBHOOK_URL_PRODUCT_RELEASES: ${{ secrets.SLACK_WEBHOOK_URL_PRODUCT_RELEASES }}
      SLACK_BOT_TOKEN_PRODUCT_RELEASES: ${{ secrets.SLACK_BOT_TOKEN_PRODUCT_RELEASES }}

  release_summary:
    needs: [get_version, notify_release]
    if: needs.notify_release.outputs.message_ts != ''
    runs-on: ubuntu-latest
    continue-on-error: true
    timeout-minutes: 15
    permissions:
      contents: read
      pull-requests: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          fetch-tags: true
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/release-summary@release-summary/v1
        with:
          version: ${{ needs.get_version.outputs.version }}
          repository: ${{ github.repository }}
          product: vCluster Platform
          github-token: ${{ github.token }}
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          slack-bot-token: ${{ secrets.SLACK_BOT_TOKEN_PRODUCT_RELEASES }}
          slack-channel-id: ${{ needs.notify_release.outputs.channel_id }}
          thread-ts: ${{ needs.notify_release.outputs.message_ts }}
```

`dry-run: 'true'` collects, summarizes and renders the reply into the job
summary without posting; it needs no Slack inputs.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT       |  TYPE  | REQUIRED |  DEFAULT   |                                                        DESCRIPTION                                                        |
|-------------------|--------|----------|------------|---------------------------------------------------------------------------------------------------------------------------|
| anthropic-api-key | string |  false   |            |                              Anthropic API key. Empty skips the <br>summary with a warning.                               |
|      dry-run      | string |  false   | `"false"`  |                     Collect, summarize and render into the <br>job summary without posting to Slack.                      |
|      effort       | string |  false   | `"medium"` |                                         ai-step effort level (low, medium, high).                                         |
|   github-token    | string |   true   |            |                          Token that can read the repository <br>pull requests through GraphQL.                            |
| linear-workspace  | string |  false   |  `"loft"`  |                                    Linear workspace slug used to link <br>issue ids.                                      |
|   previous-tag    | string |  false   |            |        Tag to compare against. Leave empty <br>to use the nearest earlier v* <br>tag that is not a -next <br>tag.         |
|      product      | string |   true   |            |                              Product name shown in the summary, <br>e.g. vCluster Platform.                               |
|    repository     | string |   true   |            | Repository the release belongs to (owner/name). <br>The checkout must be this repository <br>with full history and tags.  |
|  slack-bot-token  | string |  false   |            |           Slack bot token with chat:write in <br>the banner channel. Empty skips the <br>post with a warning.             |
| slack-channel-id  | string |  false   |            |                                      Slack channel id the banner was <br>posted to.                                       |
|     thread-ts     | string |  false   |            |                    Message ts of the release banner; <br>the summary is posted as a <br>reply to it.                      |
|      version      | string |   true   |            |                                Release tag to summarize. Must exist <br>in the checkout.                                  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT    |  TYPE  |                        DESCRIPTION                         |
|--------------|--------|------------------------------------------------------------|
|  conclusion  | string |            posted, dry-run, skipped or failed.             |
| previous-tag | string |           Tag the release was compared against.            |
|    reason    | string | One-line reason when conclusion is skipped <br>or failed.  |

<!-- AUTO-DOC-OUTPUT:END -->

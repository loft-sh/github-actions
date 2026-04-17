# AI PR review

Reusable workflow that runs an AI-powered PR review with a
caller-provided prompt. Thin wrapper around the
[`ai-pr-review` composite action](../../.github/actions/ai-pr-review/README.md) —
handles checkout, permissions, and secret plumbing for a job-level call.

## Usage

```yaml
jobs:
  risk-review:
    uses: loft-sh/github-actions/.github/workflows/ai-pr-review.yaml@main
    with:
      provider: anthropic
      effort: medium
      outcome: pr-comment
      prompt: |
        Review this PR for risk CI cannot catch: major version bumps
        where the diff is more than a version number, removed public
        exports, breaking API changes, changed defaults.
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

Compose with `auto-approve-bot-prs.yaml` as a sibling job to get an AI
review alongside auto-approve on bot PRs.

## Effort → model

| Effort | Anthropic            |
|--------|----------------------|
| low    | `claude-haiku-4-5`   |
| medium | `claude-sonnet-4-6`  |
| high   | `claude-opus-4-7`    |

## Outcome

- `pr-comment` — one sticky summary PR comment.
- `inline-review` — inline comments on specific lines.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |                     DEFAULT                     |                                 DESCRIPTION                                  |
|-----------------|--------|----------|-------------------------------------------------|------------------------------------------------------------------------------|
|  allowed-bots   | string |  false   | `"renovate,dependabot,loft-bot,github-actions"` |  Comma-separated bot logins this review runs <br>for. `*` allows all bots.   |
|     effort      | string |  false   |                   `"medium"`                    | Effort level (low | medium | high) — maps to <br>a provider-specific model.  |
|     outcome     | string |   true   |                                                 |         What the AI produces: `pr-comment` or <br>`inline-review`.           |
|     prompt      | string |   true   |                                                 |          Review instructions passed verbatim as the <br>AI prompt.           |
|    provider     | string |   true   |                                                 |   AI provider: `anthropic` (implemented) or `openai` <br>(reserved stub).    |
| timeout-minutes | number |  false   |                      `15`                       |                           Job timeout in minutes.                            |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|      SECRET       | REQUIRED |                     DESCRIPTION                      |
|-------------------|----------|------------------------------------------------------|
| anthropic-api-key |  false   | Anthropic API key. Required when provider=anthropic. |
|  openai-api-key   |  false   |    OpenAI API key. Reserved for provider=openai.     |

<!-- AUTO-DOC-SECRETS:END -->

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
      # openai-api-key: ${{ secrets.OPENAI_API_KEY }}   # when provider=openai
```

Pass only the provider-specific key your job needs. This repo is
public — do **not** use `secrets: inherit`, which would forward every
org-level secret into the reusable workflow.

Compose with `auto-approve-bot-prs.yaml` as a sibling job to get an AI
review alongside auto-approve on bot PRs.

## Effort → model

| Effort | Anthropic            | OpenAI          |
|--------|----------------------|-----------------|
| low    | `claude-haiku-4-5`   | `gpt-5.4-mini`  |
| medium | `claude-sonnet-4-6`  | `gpt-5.3-codex` |
| high   | `claude-opus-4-7`    | `gpt-5.4`       |

## Outcome

- `pr-comment` — one summary PR comment (sticky for `anthropic`,
  new comment per run for `openai`).
- `inline-review` — inline comments on specific lines. **Anthropic only**;
  `openai` + `inline-review` degrades to a notice-level skip because
  `openai/codex-action` has no inline-comment surface.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |  DEFAULT   |                                 DESCRIPTION                                  |
|-----------------|--------|----------|------------|------------------------------------------------------------------------------|
|     effort      | string |  false   | `"medium"` | Effort level (low | medium | high) — maps to <br>a provider-specific model.  |
|     prompt      | string |   true   |            |          Review instructions passed verbatim as the <br>AI prompt.           |
|    provider     | string |   true   |            |                    AI provider: `anthropic` or `openai`.                     |
| timeout-minutes | number |  false   |    `15`    |                           Job timeout in minutes.                            |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|      SECRET       | REQUIRED |                     DESCRIPTION                      |
|-------------------|----------|------------------------------------------------------|
| anthropic-api-key |  false   | Anthropic API key. Required when provider=anthropic. |
|  openai-api-key   |  false   |    OpenAI API key. Required when provider=openai.    |

<!-- AUTO-DOC-SECRETS:END -->

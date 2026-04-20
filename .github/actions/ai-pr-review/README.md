# AI PR review

Runs an AI-powered PR review. Callers control what the AI looks at
(`prompt`), how hard it thinks (`effort`), and what it produces
(`outcome`). The action owns model selection, MCP servers, and the
write-tool surface.

Advisory only — every failure mode (invalid input, stubbed provider,
API error inside claude-code-action) degrades to a notice-level skip.
Callers should set `continue-on-error: true` on the job.

## Outcomes

- `pr-comment` — one sticky summary PR comment. No inline comments.
- `inline-review` — inline comments on specific lines (summary optional).

## Effort → model

| Effort | Anthropic            | OpenAI          |
|--------|----------------------|-----------------|
| low    | `claude-haiku-4-5`   | `gpt-5.4-mini`  |
| medium | `claude-sonnet-4-6`  | `gpt-5.3-codex` |
| high   | `claude-opus-4-7`    | `gpt-5.4`       |

`openai` + `inline-review` is unsupported (codex-action has no
inline-comment surface) and degrades to a notice-level skip. Use
`openai` + `pr-comment` or switch to `anthropic` for inline reviews.

## Usage

```yaml
jobs:
  ai-review:
    runs-on: ubuntu-latest
    continue-on-error: true
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    steps:
      - uses: actions/checkout@v4
        with:
          repository: loft-sh/github-actions
          ref: main
          sparse-checkout: .github/actions/ai-pr-review
          persist-credentials: false
      - uses: ./.github/actions/ai-pr-review
        with:
          provider: anthropic
          effort: medium
          outcome: pr-comment
          prompt: |
            Review this PR for risk CI cannot catch: major version bumps
            where the diff is more than a version number, removed public
            exports, breaking API changes, changed defaults.
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

For a job-level wrapper that handles checkout and permissions for you,
use the companion reusable workflow at
`.github/workflows/ai-pr-review.yaml` instead.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT       |  TYPE  | REQUIRED |  DEFAULT   |                                                                                     DESCRIPTION                                                                                     |
|-------------------|--------|----------|------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| anthropic-api-key | string |  false   |            |                                                                Anthropic API key. Required when provider=anthropic.                                                                 |
|      effort       | string |  false   | `"medium"` |                                                    Effort level (low | medium | high) — maps to <br>a provider-specific model.                                                      |
|   github-token    | string |   true   |            |                                                      Token used by claude-code-action to post <br>comments and read PR state.                                                       |
|  openai-api-key   | string |  false   |            |                                                                   OpenAI API key. Required when provider=openai.                                                                    |
|      outcome      | string |   true   |            | What the AI produces: `pr-comment` (a summary PR comment — sticky on anthropic, new per run on openai) or <br>`inline-review` (inline comments on specific lines, anthropic only).  |
|      prompt       | string |   true   |            |                                                             Review instructions passed verbatim as the <br>AI prompt.                                                               |
|     provider      | string |   true   |            |                                                                        AI provider: `anthropic` or `openai`.                                                                        |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT   |  TYPE  |                                                         DESCRIPTION                                                         |
|------------|--------|-----------------------------------------------------------------------------------------------------------------------------|
| conclusion | string | `success` when the AI review ran; <br>`skipped` when the resolver vetoed the <br>run (invalid input or unsupported combo).  |
|   reason   | string |                                        One-line explanation when conclusion=skipped.                                        |

<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-ai-pr-review
```

Runs the bats suite in `test/` against `src/resolve-config.sh`.

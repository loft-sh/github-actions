# AI PR review

Runs an AI-powered PR review. Callers control what the AI looks at
(`prompt`) and how hard it thinks (`effort`). The action owns model
selection, comment shape, MCP servers, and the write-tool surface.

The model decides how to post findings — inline comments on specific
lines, a sticky summary comment, or both — based on the shape of the
review. Callers who want a specific shape can ask for it inside
`prompt`. Provider asymmetry: `openai` (via `codex-action`) has no
inline-comment surface, so the openai path is always summary-only.

Every posted comment ends with a provenance footer:

> _🤖 ai-pr-review — provider: anthropic · model: claude-opus-4-7 · effort: high_

Advisory only — every failure mode (invalid input, stubbed provider,
API error inside claude-code-action) degrades to a notice-level skip.
Callers should set `continue-on-error: true` on the job.

## Effort → model

| Effort | Anthropic            | OpenAI          |
|--------|----------------------|-----------------|
| low    | `claude-haiku-4-5`   | `gpt-5.4-mini`  |
| medium | `claude-sonnet-4-6`  | `gpt-5.3-codex` |
| high   | `claude-opus-4-7`    | `gpt-5.4`       |

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
|      prompt       | string |   true   |            |                                                             Review instructions passed verbatim as the <br>AI prompt.                                                               |
|     provider      | string |   true   |            |                                                                        AI provider: `anthropic` or `openai`.                                                                        |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT   |  TYPE  |                                                         DESCRIPTION                                                         |
|------------|--------|-----------------------------------------------------------------------------------------------------------------------------|
| conclusion | string | `success` when the AI review ran; <br>`skipped` when the resolver vetoed the <br>run (invalid input).  |
|   reason   | string |                                        One-line explanation when conclusion=skipped.                                        |

<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-ai-pr-review
```

Runs the bats suite in `test/` against `src/resolve-config.sh`.

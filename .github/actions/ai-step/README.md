# AI step

Small reusable building block for CI: run an AI call with a
caller-supplied prompt and input, bind the output to a JSON Schema,
expose the schema-conforming JSON as a step output. Downstream steps
parse with `fromJSON(steps.<id>.outputs.result)` and branch on typed
fields.

The contract is the schema. Whatever the model returns, the action
exposes it on `result` and sets `conclusion=success`. The action never
emits `failed` — the caller knows what empty or unexpected output means
for their pipeline, and decides whether to continue or `exit 1`.

## When to use this vs `ai-pr-review`

- **`ai-pr-review`** — job-shaped reusable workflow for reviewing PRs.
  Owns checkout, commenting, sticky summaries, provenance footer.
- **`ai-step`** — step-shaped primitive for any AI-in / JSON-out flow.
  No PR awareness, no checkout, no write permissions. Classify a diff,
  extract fields from a changelog, pick a reviewer, summarize release
  notes — anywhere you want the model's answer as typed JSON a later
  step can branch on.

## Effort → model

| Effort | Anthropic            | OpenAI          |
|--------|----------------------|-----------------|
| low    | `claude-haiku-4-5`   | `gpt-5.4-mini`  |
| medium | `claude-sonnet-4-6`  | `gpt-5.3-codex` |
| high   | `claude-opus-4-7`    | `gpt-5.4`       |

## Usage

```yaml
jobs:
  classify-diff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          repository: loft-sh/github-actions
          ref: ai-step/v1
          sparse-checkout: .github/actions/ai-step
          persist-credentials: false

      - id: diff
        run: |
          {
            echo 'text<<EOF'
            git diff origin/main...HEAD
            echo 'EOF'
          } >> "$GITHUB_OUTPUT"

      - id: classify
        uses: ./.github/actions/ai-step
        with:
          provider: anthropic
          effort: low
          prompt: |
            Classify this diff. Return JSON matching the schema.
          input: ${{ steps.diff.outputs.text }}
          output-schema: |
            {
              "type": "object",
              "required": ["severity", "areas"],
              "properties": {
                "severity": { "type": "string", "enum": ["low","medium","high"] },
                "areas":    { "type": "array",  "items": { "type": "string" } }
              }
            }
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}

      - if: steps.classify.outputs.result != '' && fromJSON(steps.classify.outputs.result).severity == 'high'
        run: echo "needs human review"
```

## Provider asymmetries

- `allowed-tools` and `mcp-config` are anthropic-only. On `openai` they
  are silently ignored — `codex-action` sandboxes tool access at the
  process level instead of exposing an allow-list.
- `openai`'s schema is forwarded verbatim to `codex exec --output-schema`;
  `anthropic`'s schema is forwarded via `--json-schema` in `claude_args`.
  Both paths accept the same JSON Schema draft syntax.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT       |  TYPE  | REQUIRED |  DEFAULT   |                                                                                                                                          DESCRIPTION                                                                                                                                           |
|-------------------|--------|----------|------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   allowed-tools   | string |  false   |            |                                                 Comma-separated allow-list forwarded to `--allowedTools` on <br>the anthropic path. Ignored on `openai` <br>(codex sandboxes tool access at the <br>process level instead of an allow-list).                                                   |
| anthropic-api-key | string |  false   |            |                                                                                                                      Anthropic API key. Required when provider=anthropic.                                                                                                                      |
|      effort       | string |  false   | `"medium"` |                                                                                                          Effort level (low | medium | high) — maps to <br>a provider-specific model.                                                                                                           |
|       input       | string |  false   |            |                                                                          Optional data the model should act <br>on, appended to the prompt. Caller <br>sources it — a literal string, <br>`${{ steps.X.outputs.Y }}`,                                                                          |
|                   |        |          |            |                                                                                                                      or the contents of a file <br>read in a prior step.                                                                                                                       |
|    mcp-config     | string |  false   |            |                                                                                                    Optional JSON passed to `--mcp-config` on <br>the anthropic path. Ignored on `openai`.                                                                                                      |
|  openai-api-key   | string |  false   |            |                                                                                                                         OpenAI API key. Required when provider=openai.                                                                                                                         |
|   output-schema   | string |   true   |            | JSON Schema (string) the model output <br>must conform to. Required. Structured output <br>is the contract — without a <br>schema the action skips. For `anthropic` this <br>is forwarded via `--json-schema` in `claude_args`; for `openai` it <br>becomes `output-schema` on `codex-action`. |
|                   |        |          |            |                                                                                                                                                                                                                                                                                                |
|      prompt       | string |   true   |            |                                                                                                                          Instructions for the model. Passed verbatim.                                                                                                                          |
|     provider      | string |   true   |            |                                                                                                                             AI provider: `anthropic` or `openai`.                                                                                                                              |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT   |  TYPE  |                                                             DESCRIPTION                                                             |
|------------|--------|-------------------------------------------------------------------------------------------------------------------------------------|
| conclusion | string |                `success` when the AI step ran; <br>`skipped` when the resolver vetoed the <br>run (invalid input).                  |
|   reason   | string |                                            One-line explanation when conclusion=skipped.                                            |
|   result   | string | Schema-conforming JSON string. Parse with `fromJSON(...)` <br>in downstream `if:` conditions. Empty when <br>`conclusion=skipped`.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-ai-step
```

Runs the bats suite in `test/` against `src/resolve-config.sh`.

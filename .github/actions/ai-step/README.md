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

## How it works

The action installs the `anthropic` or `openai` Python SDK on the
runner, then calls the provider's chat API directly with its native
structured-output binding:

- **Anthropic** → Messages API with `output_config.format.schema`
- **OpenAI** → Chat Completions with `response_format.json_schema.schema`

No `claude-code-action`, no `codex-action`, no bun install. End-to-end
call is ~15s including SDK install; the LLM call itself is 2–4s. The
action never hard-fails: API errors, empty responses, and non-JSON
content all degrade to `conclusion=failed` with the upstream body
preserved in the CI log. Caller decides how to react.

### Schema compatibility

Strict structured-output modes on both providers reject some JSON
Schema features:

- `minimum`, `maximum`, `minLength`, `maxLength`, `pattern` — rejected
- recursive schemas, `$ref` across documents — rejected
- objects: `additionalProperties` must be `false` (the action sets this
  automatically on any object node where it's missing, so you don't
  have to repeat it in every nested schema)

Structured output guarantees the **shape** of the result (fields
present, types match, enums respected). It does NOT guarantee semantic
correctness of the values — that's the model's reasoning. Validate
ranges and business rules in your downstream step, not in the schema.

### Tool use / MCP

Not supported in v1. If you need Claude Code tools, MCP servers, or
filesystem access during the reasoning step, reach for
`anthropics/claude-code-action` directly — `ai-step` is the minimal
text-to-JSON primitive.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT       |  TYPE  | REQUIRED |  DEFAULT   |                                                                                                                                            DESCRIPTION                                                                                                                                            |
|-------------------|--------|----------|------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| anthropic-api-key | string |  false   |            |                                                                                                                       Anthropic API key. Required when provider=anthropic.                                                                                                                        |
|      effort       | string |  false   | `"medium"` |                                                                                                           Effort level (low | medium | high) — maps to <br>a provider-specific model.                                                                                                             |
|       input       | string |  false   |            |                                                  Optional data the model should act <br>on, appended to the prompt. Caller <br>sources it — a literal string, <br>a prior step output, or the <br>contents of a file read in <br>a prior step.                                                    |
|  openai-api-key   | string |  false   |            |                                                                                                                          OpenAI API key. Required when provider=openai.                                                                                                                           |
|   output-schema   | string |   true   |            | JSON Schema (string) the model output <br>must conform to. Required. Structured output <br>is the contract — without a <br>schema the action skips. For `anthropic` this <br>becomes `output_format.schema` on the Messages API; for <br>`openai` it becomes `response_format.json_schema.schema` |
|                   |        |          |            |                                                                                                                                 on the Chat Completions <br>API.                                                                                                                                  |
|      prompt       | string |   true   |            |                                                                                                                           Instructions for the model. Passed verbatim.                                                                                                                            |
|     provider      | string |   true   |            |                                                                                                                               AI provider: `anthropic` or `openai`.                                                                                                                               |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT   |  TYPE  |                                                                              DESCRIPTION                                                                              |
|------------|--------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| conclusion | string | `success` when the AI step ran <br>and returned JSON; `skipped` when the <br>resolver vetoed the input; `failed` when <br>the provider errored or returned non-JSON.  |
|   reason   | string |                                                             One-line explanation when conclusion=skipped.                                                             |
|   result   | string |             Schema-conforming JSON string. Parse with `fromJSON(...)` <br>in downstream `if:` conditions. Empty when <br>`conclusion` is not `success`.               |

<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-ai-step
```

Runs the bats suite in `test/` against `src/resolve-config.sh`.

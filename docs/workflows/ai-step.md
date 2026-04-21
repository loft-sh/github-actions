# AI step — design

> Design doc backing the `ai-step` composite action (DEVOPS-834).
> Implementation lives at `.github/actions/ai-step/` — see the
> [action README](../../.github/actions/ai-step/README.md) for inputs,
> outputs, and usage examples.

## Problem

We have `ai-pr-review`: a composite action + reusable workflow that
drops into any CI and runs an AI-powered PR review. It owns a lot of
context (checkout, PR comments, sticky summary, inline comments,
provenance footer). That's the right shape for the "review a PR" job.

But CI has other jobs that want the same primitive for different ends:
classify a diff, extract fields from a changelog, decide whether to
backport, pick a reviewer, summarize release notes into a structured
object. The common shape is:

```
<arbitrary text or step output>  ──►  AI  ──►  <JSON matching my schema>
```

…where the downstream step reads the JSON via
`fromJSON(steps.ai.outputs.result)` and branches on typed fields.

`ai-pr-review` is the wrong entry point for this — it is PR-shaped,
opinionated, and advisory-only. Generalizing it would bloat the input
surface and couple unrelated concerns.

## Proposal

A new, **small** composite action: `ai-step`.

One job: take text in, call an AI, return **schema-conforming JSON** on
a single output. No PR awareness, no comments, no checkout. The caller
owns everything around it (what to feed in, what to do with the JSON).

`ai-pr-review` stays as-is. `ai-step` is the building block; other
callers (including, eventually, `ai-pr-review` itself) can reuse it.

## Name

**`ai-step`** — reads as "an AI-powered CI step." Short, neutral,
composable. Rejected alternatives: `ai-agent` (overloaded), `ai-transform`
(verbose), `ai-structured` (implementation leaking into the name).

## Shape

### Inputs

| input             | required | notes |
|-------------------|----------|-------|
| `provider`        | yes      | `anthropic` only for MVP. `openai` placeholder returning a skip. |
| `effort`          | no       | `low|medium|high`; same mapping table as `ai-pr-review`. |
| `prompt`          | yes      | Instructions for the model. |
| `input`           | no       | Text fed to the model alongside the prompt. Caller sources it — a literal string, `${{ steps.X.outputs.Y }}`, or a file read via a prior step. No `input_file` / `step_output` dispatch inside the action. |
| `output-schema`   | yes      | JSON Schema (string). The model's final output must conform. |
| `tools`           | no       | Allowed-tools list passed to `--allowedTools`. Defaults to empty (pure text→JSON, no tool use). |
| `mcp-config`      | no       | Optional MCP-server JSON passed to `--mcp-config`. |
| `anthropic-api-key` | conditionally | Required when `provider=anthropic`. |
| `fail-on-invalid` | no       | `false` (default) — invalid schema / empty result emits `conclusion=failed` and empty `result`, never hard-fails. `true` — exit 1 on failure so the job goes red. |

Flat inputs, no arrays. Conflict rules are trivial enough that shell validation in `resolve-config.sh` covers them.

### Outputs

| output       | notes |
|--------------|-------|
| `result`     | JSON string matching `output-schema`. Consume with `fromJSON(...)`. Empty when `conclusion != success`. |
| `conclusion` | `success` / `skipped` / `failed`. Mirrors `ai-pr-review`'s shape. |
| `reason`     | One-line explanation when not `success`. |

### Internals

Direct API calls via the official Python SDKs:

- `anthropic` SDK → Messages API with `output_config.format.schema`
- `openai` SDK → Chat Completions with `response_format.json_schema.schema`

The action installs the needed SDK on the runner, calls the provider,
extracts the model's text content, and validates it parses as JSON
before emitting `result`. Any failure (API error, empty content,
non-JSON response) degrades to `conclusion=failed` with the upstream
body preserved in the CI log. End-to-end ~15s including SDK install.

The earlier draft of this design wrapped `anthropics/claude-code-action`
and `openai/codex-action`, relying on their `--json-schema` /
`output-schema` flags. Smoke testing surfaced a ~90s cold-start cost
plus a directory-mismatch hang unrelated to schema binding — both
rooted in the wrappers' PR-review machinery we didn't need. Direct
SDK calls dropped that for a simpler, faster primitive.

No checkout. No `GITHUB_TOKEN`. No write permissions. The caller
provides data and decides what to do with the JSON.

### Schema compatibility

Both providers' strict structured-output modes reject some JSON
Schema features. The action enforces one implicitly and documents
the rest:

- `additionalProperties: false` is set automatically on any object
  node where it's missing (both providers require it in strict mode)
- `minimum` / `maximum` / `minLength` / `maxLength` / `pattern` are
  rejected by Anthropic — callers validate ranges in a downstream step
- Recursive schemas and `$ref` across documents are rejected

## Usage

```yaml
jobs:
  classify-diff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          sparse-checkout: .github/actions/ai-step

      - id: diff
        run: echo "text=$(git diff origin/main...HEAD)" >> "$GITHUB_OUTPUT"

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

      - if: fromJSON(steps.classify.outputs.result).severity == 'high'
        run: echo "needs human review"
```

## Out of scope (intentional)

- **`openai` provider.** `openai/codex-action` is unmaintained upstream,
  and the Claude path alone delivers the primitive. Add later if a
  caller needs provider choice.
- **Input dispatch (`input_file`, `step_output.<id>.<name>`).** Callers
  already have GHA expressions; adding a second dispatch layer is
  bloat.
- **Destinations / `output_actions` array.** The output *is* structured
  JSON on a step output. Posting to Slack, opening an issue, commenting
  on a PR — each is one extra step the caller writes, not a mode inside
  this action.
- **Reusable workflow wrapper.** `ai-step` is a composite used inside
  a user-defined job. There is no job shape to reuse — each caller's
  surrounding job does different things.

## Testing

Same pattern as `ai-pr-review`:
- `test/resolve-config.bats` covers input validation, effort→model
  mapping, conflict rules, and schema-present checks.
- End-to-end coverage via a scenario workflow in a dedicated e2e repo
  (the pattern in `docs/workflows/auto-approve-bot-prs.md`), if we want
  signal on upstream regressions.

## Release

Tag `ai-step/v1` once merged and a smoke call against this repo's own
CI returns valid JSON twice in a row (covers the cold-start quirk).

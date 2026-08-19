# AI step

Small reusable building block for CI: run an AI call with a
caller-supplied prompt and input, bind the output to a JSON Schema,
expose the schema-conforming JSON as a step output. Downstream steps
parse with `fromJSON(steps.<id>.outputs.result)` and branch on typed
fields.

The contract is the schema. When the model returns schema-conforming
JSON, the action exposes it on `result` and sets `conclusion=success`.
The action never hard-fails the pipeline: provider errors, timeouts,
and non-JSON output all degrade to `conclusion=failed` with an empty
`result`, a `::warning::` in the log, and exit code 0. The caller knows
what a failed or empty result means for their pipeline, and decides
whether to continue or `exit 1`.

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

Not supported in the single-call mode. If you need Claude Code tools,
MCP servers, or filesystem access during the reasoning step, reach for
`anthropics/claude-code-action` directly, or point the `agent` input at
a deployed managed agent (below) — the single-call mode stays the
minimal text-to-JSON primitive.

## Session mode: trigger a deployed managed agent

Setting `agent` to the name of a deployed managed agent
(`loft-sh/ai-agents`: `pr-review-lead`, `sre-router`, ...) switches the
action from a one-shot Messages call to a managed-agent session. The
`prompt` and `input` become the session's opening user message, the
agent runs with its own tools, MCP servers, and sandbox, and its final
message lands on `result` — validated against `output-schema` on the
runner, since sessions have no provider-side structured-output binding.
Downstream steps and the `conclusion` contract do not change.

```yaml
- id: agent
  uses: ./.github/actions/ai-step
  with:
    provider: anthropic
    agent: sre-router
    prompt: |
      Investigate the alert below and return JSON matching the schema.
    input: ${{ steps.alert.outputs.payload }}
    output-schema: |
      { "type": "object", "required": ["severity"], "properties":
        { "severity": { "type": "string", "enum": ["page","ticket","ignore"] } } }
    anthropic-session-key: ${{ secrets.ANTHROPIC_SESSION_KEY }}
    vault-id: vlt_...          # only if the agent's MCP servers need it
    session-timeout-seconds: '900'
```

Read this before wiring it into a pipeline:

- **Anthropic-only.** `agent` with `provider: openai` skips with a
  reason — there is no OpenAI counterpart to the deployed agents.
- **Cost and latency change class.** A single call is ~15s and one
  model invocation; a session runs minutes and is billed at session
  scale (a pr-review panel run measures $20-47). Keep this mode behind
  an explicit per-caller opt-in, never on a default PR path.
- **The credential is different.** `anthropic-session-key` must be an
  API key for the Console workspace the agent is deployed in. The
  Messages-API `ANTHROPIC_API_KEY` cannot call the sessions API, and
  workspace keys do not cross workspaces. Never expose the key to fork
  PRs: callers inherit `ai-pr-review`'s same-repo guard
  (`github.event.pull_request.head.repo.full_name == github.repository`)
  and must not use `secrets: inherit`.
- **Vaults.** Agents whose MCP servers authenticate through
  session-scoped vault credentials need `vault-id` or their MCP servers
  fail to initialize. A vault id names a resource, not a credential.
- **The agent's final message lands in public CI logs.** `result` and
  the raw output on validation failure are printed unmasked. A
  vault-backed agent can read credential-authorized material, and a
  prompt-injected turn can try to make it echo what it read, so never
  point an agent whose output may contain secret material at this
  action, and treat the agent's output as untrusted input downstream.
- **Outbound network is unrestricted.** The per-run environment is
  created with unrestricted egress, matching how the deployed products
  run. The API's `limited` mode needs a per-agent host allowlist this
  generic trigger cannot know; a caller-facing knob is deliberate
  follow-up work if a caller needs narrower egress.
- **Completion is polled, not streamed.** The action polls session
  status until it leaves `running` and gates on `stop_reason=end_turn`
  (a visible answer is not a finished session — ai-agents PR #81). A
  session that outlives `session-timeout-seconds` ends the step with
  `conclusion=failed`.
- **Sessions are always deleted.** Every session (and its per-run
  environment) the action creates is deleted before the step ends, on
  success, failure, and timeout alike. A run you want to inspect in the
  Console belongs in `ai-agents`' own tooling, not CI.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|          INPUT          |  TYPE  | REQUIRED |  DEFAULT   |                                                                                                                                                                                                                                                DESCRIPTION                                                                                                                                                                                                                                                |
|-------------------------|--------|----------|------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|          agent          | string |  false   |            | Optional name of a deployed managed <br>agent (loft-sh/ai-agents). When set, the action <br>creates a managed-agent session against that <br>agent instead of a one-shot Messages <br>call: prompt and input become the <br>session's opening user message, and the <br>agent's final output lands on the <br>result output. Anthropic-only — combined with <br>provider openai the step skips with <br>a reason. Expect minutes of latency <br>and session-scale cost instead of a <br>15s single call.  |
|    anthropic-api-key    | string |  false   |            |                                                                                                                                                                                                                           Anthropic API key. Required when provider=anthropic.                                                                                                                                                                                                                            |
|  anthropic-session-key  | string |  false   |            |                                                                                                       Anthropic Console API key for the <br>workspace the agent is deployed in. <br>Required when agent is set. This <br>is a different credential class from <br>anthropic-api-key: Messages-API and admin keys cannot <br>call the sessions API, and workspace <br>keys do not cross workspaces.                                                                                                        |
|         effort          | string |  false   | `"medium"` |                                                                                                                                                                                                               Effort level (low | medium | high) — maps to <br>a provider-specific model.                                                                                                                                                                                                                 |
|          input          | string |  false   |            |                                                                                                                                                      Optional data the model should act <br>on, appended to the prompt. Caller <br>sources it — a literal string, <br>a prior step output, or the <br>contents of a file read in <br>a prior step.                                                                                                                                                        |
|     openai-api-key      | string |  false   |            |                                                                                                                                                                                                                              OpenAI API key. Required when provider=openai.                                                                                                                                                                                                                               |
|      output-schema      | string |   true   |            |                                                                                                     JSON Schema (string) the model output <br>must conform to. Required. Structured output <br>is the contract — without a <br>schema the action skips. For `anthropic` this <br>becomes `output_format.schema` on the Messages API; for <br>`openai` it becomes `response_format.json_schema.schema`                                                                                                     |
|                         |        |          |            |                                                                                                                                                                                                                                     on the Chat Completions <br>API.                                                                                                                                                                                                                                      |
|         prompt          | string |   true   |            |                                                                                                                                                                                                                               Instructions for the model. Passed verbatim.                                                                                                                                                                                                                                |
|        provider         | string |   true   |            |                                                                                                                                                                                                                                   AI provider: `anthropic` or `openai`.                                                                                                                                                                                                                                   |
| session-timeout-seconds | string |  false   |  `"1200"`  |                                                                                                                                                                                       How long to wait for the <br>session to finish before giving up <br>with conclusion=failed. Only used when agent <br>is set.                                                                                                                                                                                        |
|        vault-id         | string |  false   |            |                                                                                                      Optional vault id to attach to <br>the session. Agents whose MCP servers <br>authenticate through session-scoped vault credentials need <br>it or their MCP servers fail <br>to initialize. A vault id names <br>a resource, not a credential, so <br>it is safe to pass as <br>a plain input.                                                                                                       |

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

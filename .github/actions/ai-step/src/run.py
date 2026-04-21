#!/usr/bin/env python3
"""Call the provider's chat API with response_format / output_format
bound to the caller's JSON Schema. Writes the model's schema-conforming
output to $GITHUB_OUTPUT as `result`.

The action is advisory-only: any failure (bad schema, API error, empty
content, non-JSON response) degrades to `conclusion=failed` with the
upstream body preserved in the CI log. The caller decides how to react.

Env in:
  INPUT_PROVIDER          anthropic | openai
  INPUT_MODEL             provider-specific model id
  INPUT_PROMPT            instructions
  INPUT_OUTPUT_SCHEMA     JSON Schema string
  INPUT_INPUT             optional data appended to the prompt
  INPUT_ANTHROPIC_API_KEY required when provider=anthropic
  INPUT_OPENAI_API_KEY    required when provider=openai
Env out ($GITHUB_OUTPUT):
  result                  the schema-conforming JSON string (or empty)
  conclusion              success | failed
"""
from __future__ import annotations

import json
import os
import sys


def emit_block(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as f:
        f.write(f"{key}<<AISTEP_EOF\n{value}\nAISTEP_EOF\n")


def emit_kv(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as f:
        f.write(f"{key}={value}\n")


def fail_soft(msg: str, body: str = "") -> None:
    print(f"::warning::ai-step: {msg}")
    if body:
        print("--- upstream response ---")
        print(body)
        print("--- end ---")
    emit_block("result", "")
    emit_kv("conclusion", "failed")
    sys.exit(0)


def require(name: str) -> str:
    v = os.environ.get(name, "")
    if not v:
        print(f"::error::missing required env {name}")
        sys.exit(1)
    return v


def call_anthropic(model: str, user_content: str, schema: dict, api_key: str) -> str:
    try:
        from anthropic import Anthropic, APIError  # type: ignore
    except ImportError:
        fail_soft("anthropic SDK not installed")

    client = Anthropic(api_key=api_key)
    try:
        resp = client.messages.create(
            model=model,
            max_tokens=4096,
            messages=[{"role": "user", "content": user_content}],
            output_config={"format": {"type": "json_schema", "schema": schema}},
        )
    except APIError as e:
        fail_soft(f"anthropic API error: {e}", getattr(e, "body", ""))
    except Exception as e:
        fail_soft(f"anthropic request failed: {e}")

    if not resp.content:
        fail_soft("empty content from anthropic", json.dumps(resp.model_dump(), indent=2))
    # Structured-output responses still land in content[0].text — the
    # text payload is guaranteed to parse against the schema.
    return resp.content[0].text


def call_openai(model: str, user_content: str, schema: dict, api_key: str) -> str:
    try:
        from openai import OpenAI, APIError  # type: ignore
    except ImportError:
        fail_soft("openai SDK not installed")

    client = OpenAI(api_key=api_key)
    try:
        resp = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": user_content}],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "ai_step_output",
                    "schema": schema,
                    "strict": True,
                },
            },
        )
    except APIError as e:
        fail_soft(f"openai API error: {e}", getattr(e, "body", ""))
    except Exception as e:
        fail_soft(f"openai request failed: {e}")

    text = resp.choices[0].message.content
    if text is None:
        fail_soft("empty content from openai", json.dumps(resp.model_dump(), indent=2))
    return text


def main() -> None:
    provider = require("INPUT_PROVIDER")
    model = require("INPUT_MODEL")
    prompt = require("INPUT_PROMPT")
    schema_raw = require("INPUT_OUTPUT_SCHEMA")
    input_text = os.environ.get("INPUT_INPUT", "")

    try:
        schema = json.loads(schema_raw)
    except json.JSONDecodeError as e:
        fail_soft(f"output-schema is not valid JSON: {e}")

    user_content = f"{prompt}\n\n{input_text}" if input_text else prompt

    if provider == "anthropic":
        api_key = os.environ.get("INPUT_ANTHROPIC_API_KEY", "")
        if not api_key:
            fail_soft("anthropic-api-key required when provider=anthropic")
        text = call_anthropic(model, user_content, schema, api_key)
    elif provider == "openai":
        api_key = os.environ.get("INPUT_OPENAI_API_KEY", "")
        if not api_key:
            fail_soft("openai-api-key required when provider=openai")
        text = call_openai(model, user_content, schema, api_key)
    else:
        fail_soft(f"unknown provider: {provider}")

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        fail_soft("provider returned non-JSON content", text)

    emit_block("result", text)
    emit_kv("conclusion", "success")

    print(f"ai-step: {provider} / {model} → success")
    print(json.dumps(parsed, indent=2))


if __name__ == "__main__":
    main()

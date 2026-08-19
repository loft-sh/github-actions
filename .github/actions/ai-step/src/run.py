#!/usr/bin/env python3
"""Call the provider's chat API with response_format / output_format
bound to the caller's JSON Schema, or (session mode) drive a deployed
managed agent through one session turn. Writes the schema-conforming
output to $GITHUB_OUTPUT as `result`.

The action is advisory-only: any failure (bad schema, API error, empty
content, non-JSON response, session timeout, non-end_turn stop) degrades
to `conclusion=failed` with the upstream body preserved in the CI log.
The caller decides how to react.

Env in:
  INPUT_PROVIDER          anthropic | openai
  INPUT_MODE              single | session (from resolve-config.sh)
  INPUT_MODEL             provider-specific model id (single mode)
  INPUT_PROMPT            instructions
  INPUT_OUTPUT_SCHEMA     JSON Schema string
  INPUT_INPUT             optional data appended to the prompt
  INPUT_ANTHROPIC_API_KEY required when provider=anthropic (single mode)
  INPUT_OPENAI_API_KEY    required when provider=openai
  INPUT_AGENT             deployed agent name (session mode)
  INPUT_ANTHROPIC_SESSION_KEY workspace session key (session mode)
  INPUT_VAULT_ID          optional vault to attach (session mode)
  INPUT_SESSION_TIMEOUT   seconds to wait for the session (session mode)
Env out ($GITHUB_OUTPUT):
  result                  the schema-conforming JSON string (or empty)
  conclusion              success | failed
"""
from __future__ import annotations

import json
import os
import sys
import time

# Managed agents GA beta header, same as pr-review/src/cma.py in
# loft-sh/ai-agents.
BETA_HEADER = "managed-agents-2026-04-01"
POLL_INTERVAL_S = 10


def enforce_strict(node):
    """Walk the schema and set `additionalProperties: false` on every
    object node that doesn't already specify it. Both Anthropic and
    OpenAI strict structured-output modes require this; making it
    implicit means callers don't have to repeat it on every nested
    object in their schema."""
    if isinstance(node, dict):
        if node.get("type") == "object" and "additionalProperties" not in node:
            node["additionalProperties"] = False
        for v in node.values():
            enforce_strict(v)
    elif isinstance(node, list):
        for item in node:
            enforce_strict(item)
    return node


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


def latest_event(client, session_id: str, event_type: str):
    """Newest event of one type on the session, or None."""
    for ev in client.beta.sessions.events.list(
        session_id, types=[event_type], order="desc", limit=1
    ):
        return ev
    return None


def run_session(agent_name: str, user_content: str, api_key: str,
                vault_id: str, timeout_s: int) -> str:
    """Drive one turn against a deployed managed agent: resolve the agent
    by name, create a per-run environment, open a session (attaching the
    vault when given), send the user message, poll session status until
    it leaves running (ai-agents PR #81: a visible answer is not a
    finished session, so never trust a stream idle event), gate on
    stop_reason, and return the agent's final message text. The session
    and environment are deleted on every path — a leaked CI session
    keeps billing."""
    from anthropic import Anthropic, APIError  # type: ignore

    client = Anthropic(api_key=api_key,
                       default_headers={"anthropic-beta": BETA_HEADER})

    agent_id = None
    try:
        for a in client.beta.agents.list():
            if getattr(a, "name", None) == agent_name:
                agent_id = a.id
                break
    except APIError as e:
        fail_soft(f"could not list agents: {e}", getattr(e, "body", ""))
    except Exception as e:
        fail_soft(f"agent lookup failed: {e}")
    if agent_id is None:
        fail_soft(f"agent '{agent_name}' not found — check the name and that "
                  "anthropic-session-key belongs to the agent's workspace")

    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    try:
        # Networking is unrestricted like every deployed product's
        # environment (ai-agents ensure_env): the API's narrower
        # `limited` mode needs a per-agent host allowlist this generic
        # trigger cannot know. Narrowing per caller is follow-up work.
        env = client.beta.environments.create(
            name=f"ai-step-{run_id}-{os.urandom(3).hex()}",
            config={"type": "cloud", "networking": {"type": "unrestricted"}},
        )
    except APIError as e:
        fail_soft(f"could not create environment: {e}", getattr(e, "body", ""))
    except Exception as e:
        fail_soft(f"environment creation failed: {e}")

    session = None
    try:
        kwargs: dict = {"agent": agent_id, "environment_id": env.id,
                        "title": f"ai-step {os.environ.get('GITHUB_REPOSITORY', '')}#{run_id}"}
        if vault_id:
            kwargs["vault_ids"] = [vault_id]
        session = client.beta.sessions.create(**kwargs)
        print(f"ai-step: session {session.id} against agent '{agent_name}'")
        client.beta.sessions.events.send(
            session.id,
            events=[{"type": "user.message",
                     "content": [{"type": "text", "text": user_content}]}],
        )

        deadline = time.time() + timeout_s
        status = "running"
        while time.time() < deadline:
            status = client.beta.sessions.retrieve(session.id).status
            if status in ("idle", "terminated"):
                break
            time.sleep(POLL_INTERVAL_S)

        if status not in ("idle", "terminated"):
            fail_soft(f"session still '{status}' after {timeout_s}s — raise "
                      "session-timeout-seconds or pick a faster agent")
        if status == "terminated":
            fail_soft("session terminated before producing output")

        idle = latest_event(client, session.id, "session.status_idle")
        stop = getattr(getattr(idle, "stop_reason", None), "type", None)
        if stop != "end_turn":
            fail_soft(f"session stopped with stop_reason '{stop}' instead of "
                      "end_turn — the agent did not complete its turn")

        msg = latest_event(client, session.id, "agent.message")
        if msg is None:
            fail_soft("session went idle without an agent message")
        return "\n".join(b.text for b in msg.content
                         if getattr(b, "type", "") == "text")
    except APIError as e:
        fail_soft(f"anthropic API error during session: {e}",
                  getattr(e, "body", ""))
    except Exception as e:
        # Mirror the APIError handler so an unexpected response shape
        # (a retrieve without .status, an event without .stop_reason)
        # still fails soft instead of exiting non-zero; SystemExit from
        # fail_soft passes through untouched.
        fail_soft(f"session mode failed unexpectedly: {e}")
    finally:
        # Delete unconditionally, even on the timeout path where the
        # session may still be running: leaving it up spends tokens with
        # nobody reading the result.
        if session is not None:
            try:
                client.beta.sessions.delete(session.id)
                print(f"ai-step: session {session.id} deleted")
            except Exception as e:
                print(f"::warning::ai-step: could not delete session "
                      f"{session.id}: {e} — delete it in the Console")
        try:
            client.beta.environments.delete(env.id)
        except Exception as e:
            print(f"::warning::ai-step: could not delete environment "
                  f"{env.id}: {e} — delete it in the Console")


def validate_output(parsed, schema, text: str) -> None:
    """Sessions have no provider-side structured-output binding, so the
    schema contract is enforced here instead."""
    try:
        import jsonschema  # type: ignore
    except ImportError:
        fail_soft("jsonschema not installed — cannot validate session output")
    try:
        jsonschema.validate(parsed, schema)
    except jsonschema.ValidationError as e:
        fail_soft(f"agent output does not validate against output-schema: "
                  f"{e.message}", text)
    except jsonschema.SchemaError as e:
        fail_soft(f"output-schema is not a valid JSON Schema: {e.message}")


def main() -> None:
    provider = require("INPUT_PROVIDER")
    mode = os.environ.get("INPUT_MODE", "") or "single"
    prompt = require("INPUT_PROMPT")
    schema_raw = require("INPUT_OUTPUT_SCHEMA")
    input_text = os.environ.get("INPUT_INPUT", "")

    try:
        schema = json.loads(schema_raw)
    except json.JSONDecodeError as e:
        fail_soft(f"output-schema is not valid JSON: {e}")

    user_content = f"{prompt}\n\n{input_text}" if input_text else prompt

    if mode == "session":
        agent_name = require("INPUT_AGENT")
        api_key = os.environ.get("INPUT_ANTHROPIC_SESSION_KEY", "")
        if not api_key:
            fail_soft("anthropic-session-key required when agent is set")
        try:
            timeout_s = int(os.environ.get("INPUT_SESSION_TIMEOUT", "1200"))
        except ValueError:
            fail_soft("session-timeout-seconds must be an integer")
        vault_id = os.environ.get("INPUT_VAULT_ID", "").strip()
        text = run_session(agent_name, user_content, api_key, vault_id,
                           timeout_s)
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            fail_soft("agent returned non-JSON content", text)
        # Session output is validated against the caller's schema as
        # written — enforce_strict is a provider-binding requirement,
        # not part of the caller's contract.
        validate_output(parsed, schema, text)
        emit_block("result", text)
        emit_kv("conclusion", "success")
        print(f"ai-step: session against '{agent_name}' → success")
        print(json.dumps(parsed, indent=2))
        return

    model = require("INPUT_MODEL")
    enforce_strict(schema)

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

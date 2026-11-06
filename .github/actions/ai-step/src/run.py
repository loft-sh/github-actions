#!/usr/bin/env python3
"""Call the provider's chat API with response_format / output_format
bound to the caller's JSON Schema, or (session mode) drive a deployed
managed agent through one session turn. Writes the schema-conforming
output to $GITHUB_OUTPUT as `result`.

The action is advisory-only: any failure (bad schema, API error, empty
content, non-JSON response, session timeout, non-end_turn stop) degrades
to `conclusion=failed` with the upstream body preserved in the CI log,
unless the caller set log-output to false. The caller decides how to
react.

Env in:
  INPUT_PROVIDER          anthropic | openai
  INPUT_MODE              single | session (from resolve-config.sh)
  INPUT_MODEL             provider-specific model id (single mode)
  INPUT_PROMPT            instructions
  INPUT_OUTPUT_SCHEMA     JSON Schema string
  INPUT_INPUT             optional data appended to the prompt
  INPUT_INPUT_FILE        optional file appended after INPUT_INPUT
  INPUT_MAX_TOKENS        output token limit, anthropic single mode (default 4096)
  INPUT_ANTHROPIC_API_KEY required when provider=anthropic (single mode)
  INPUT_OPENAI_API_KEY    required when provider=openai
  INPUT_AGENT             deployed agent name (session mode)
  INPUT_ANTHROPIC_SESSION_KEY workspace session key (session mode)
  INPUT_VAULT_ID          optional vault to attach (session mode)
  INPUT_SESSION_TIMEOUT   seconds to wait for the session (session mode)
  INPUT_LOG_OUTPUT        false keeps the answer and upstream bodies out
                          of the job log (default true)
Env out ($GITHUB_OUTPUT):
  result                  the schema-conforming JSON string (or empty)
  result-file             path to a file in $RUNNER_TEMP holding the same
                          text as `result`
  conclusion              success | failed
  reason                  one-line explanation when conclusion=failed
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone

# Managed agents GA beta header, same as pr-review/src/cma.py in
# loft-sh/ai-agents.
BETA_HEADER = "managed-agents-2026-04-01"
POLL_INTERVAL_S = 10
# sessions.retrieve flips to idle slightly before the session.status_idle
# event is visible in the event log (observed live on the DEVOPS-1352 wif
# smoke, ai-agents run 32252874325), so the stop_reason lookup retries for
# a bounded grace window instead of failing on the first empty read.
STOP_REASON_GRACE_S = 60
DEFAULT_MAX_TOKENS = 4096
# The Anthropic SDK refuses a non-streaming messages.create when the
# request implies more than 10 minutes of generation: 3600 s * max_tokens
# / 128000 > 600, i.e. max_tokens > 21333 (BaseClient.
# _calculate_nonstreaming_timeout in anthropic/_base_client.py, identical
# from 0.52.0 through 1.13.0). resolve-config.sh enforces the same bound
# as a skip; change both together.
ANTHROPIC_MAX_TOKENS_CAP = 21333
# `reason` is a single-line GITHUB_OUTPUT value; keep it short enough to
# post in a chat message.
REASON_MAX_LEN = 500


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


def emit_result(text: str) -> None:
    """Put the answer on `result`, and in a file named by `result-file`.
    A caller can only hand `result` to its next step through env: or the
    script text, and GitHub prints both in the step log, so a caller that
    keeps the answer out of the log reads the file instead. The file is
    private to the runner user (mkstemp) and empty on failure."""
    emit_block("result", text)
    try:
        base = os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()
        fd, path = tempfile.mkstemp(prefix="ai-step-result-", suffix=".json", dir=base)
        with os.fdopen(fd, "w") as f:
            f.write(text)
    except OSError as e:
        print(f"::warning::ai-step: could not write result-file: {e}")
        return
    emit_kv("result-file", path)


def emit_kv(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as f:
        f.write(f"{key}={value}\n")


def one_line(msg: str) -> str:
    """Collapse all whitespace so the text is safe as a `key=value`
    GITHUB_OUTPUT line (a newline would start a new output), and cap its
    length."""
    flat = " ".join(msg.split())
    if len(flat) > REASON_MAX_LEN:
        flat = flat[: REASON_MAX_LEN - 3] + "..."
    return flat


def log_output() -> bool:
    """False when the caller set log-output: false because the answer
    may quote secrets or log lines a later step redacts. The answer
    still lands on `result`; only the job log leaves it out."""
    return os.environ.get("INPUT_LOG_OUTPUT", "true").strip().lower() != "false"


def fail_soft(msg: str, body: str = "") -> None:
    print(f"::warning::ai-step: {msg}")
    if body and log_output():
        print("--- upstream response ---")
        print(body)
        print("--- end ---")
    elif body:
        print("ai-step: upstream response withheld (log-output: false)")
    emit_result("")
    emit_kv("conclusion", "failed")
    # surfaced as the action's `reason` output so a caller can show why
    # without reading the log
    emit_kv("reason", one_line(msg))
    sys.exit(0)


def read_input() -> str:
    """Inline input followed by the contents of input-file.

    input-file exists because inputs travel as env vars, and a single
    env var over 128 KiB stops the step from starting at all."""
    parts = [os.environ.get("INPUT_INPUT", "")]
    path = os.environ.get("INPUT_INPUT_FILE", "").strip()
    if path:
        try:
            # errors="replace": a stray non-UTF-8 byte becomes U+FFFD,
            # which the model tolerates, instead of a UnicodeDecodeError
            # that would end the step with a traceback and exit 1
            with open(path, encoding="utf-8", errors="replace") as f:
                parts.append(f.read())
        except OSError as e:
            fail_soft(f"input-file could not be read: {e}")
    return "\n\n".join(p for p in parts if p)


def require(name: str) -> str:
    v = os.environ.get(name, "")
    if not v:
        print(f"::error::missing required env {name}")
        sys.exit(1)
    return v


def parse_max_tokens(provider: str) -> int:
    """INPUT_MAX_TOKENS as a positive integer; empty means the default.
    resolve-config.sh already skips invalid values, so this is the second
    line of defense for a direct run. The SDK's non-streaming bound only
    applies to anthropic."""
    raw = os.environ.get("INPUT_MAX_TOKENS", "") or str(DEFAULT_MAX_TOKENS)
    # Strip leading zeros the way resolve-config.sh does; int() on the raw
    # string raises past 4300 digits, which would end the step with exit 1.
    digits = raw.lstrip("0")
    if not (raw.isascii() and raw.isdigit()) or not digits or len(digits) > 9:
        fail_soft(f"max-tokens must be a positive integer below 10^9, got '{one_line(raw)[:40]}'")
    n = int(digits)
    if provider == "anthropic" and n > ANTHROPIC_MAX_TOKENS_CAP:
        fail_soft(f"max-tokens {n} is above {ANTHROPIC_MAX_TOKENS_CAP}, the "
                  "largest value the Anthropic SDK accepts without streaming; "
                  "lower max-tokens")
    return n


def call_anthropic(model: str, user_content: str, schema: dict, api_key: str,
                   max_tokens: int = DEFAULT_MAX_TOKENS) -> str:
    try:
        from anthropic import Anthropic, APIError  # type: ignore
    except ImportError:
        fail_soft("anthropic SDK not installed")

    client = Anthropic(api_key=api_key)
    try:
        resp = client.messages.create(
            model=model,
            max_tokens=max_tokens,
            messages=[{"role": "user", "content": user_content}],
            output_config={"format": {"type": "json_schema", "schema": schema}},
        )
    except APIError as e:
        fail_soft(f"anthropic API error: {e}", getattr(e, "body", ""))
    except Exception as e:
        fail_soft(f"anthropic request failed: {e}")

    # A response cut off at the limit is partial JSON; say so instead of
    # letting it surface as a confusing JSON parse failure.
    if getattr(resp, "stop_reason", None) == "max_tokens":
        partial = resp.content[0].text if resp.content else ""
        fail_soft(f"response truncated at max-tokens {max_tokens}; raise "
                  "max-tokens", partial)
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

    choice = resp.choices[0]
    text = choice.message.content
    # No token limit is set on this call (max-tokens is anthropic-only), so
    # "length" means the model's own output limit was hit.
    if getattr(choice, "finish_reason", None) == "length":
        fail_soft("response truncated at the model's output limit "
                  "(finish_reason=length)", text or "")
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


def event_is_newer_than(event, sent_at: datetime | None) -> bool:
    """Return true only when an event has a parseable timestamp after our
    user message. Missing timestamps fail closed: an old idle event must
    never make a newly-created turn look complete."""
    if sent_at is None:
        return False
    created_at = getattr(event, "processed_at", None) or getattr(event, "created_at", None)
    if isinstance(created_at, str):
        try:
            created_at = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        except ValueError:
            return False
    if not isinstance(created_at, datetime):
        return False
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    return created_at > sent_at


def run_session(agent_name: str, user_content: str, api_key: str,
                vault_id: str, timeout_s: int) -> str:
    """Drive one turn against a deployed managed agent: resolve the agent
    by name, create a per-run environment, open a session (attaching the
    vault when given), send the user message, wait for a confirmed idle
    transition, gate on stop_reason, and return the agent's final message.
    A running session is interrupted and confirmed stopped before teardown;
    uncertain sessions keep their environment to avoid breaking active tools."""
    from anthropic import Anthropic, APIError  # type: ignore

    if api_key:
        # GitHub only auto-masks values sourced from secrets.*; masking
        # here scrubs the key from every log line no matter where the
        # caller sourced it (workflow commands are intercepted by the
        # runner, the value never lands in the log).
        print(f"::add-mask::{api_key}")
        client = Anthropic(api_key=api_key,
                           default_headers={"anthropic-beta": BETA_HEADER})
    else:
        # No explicit key: let the SDK's credential chain resolve, which
        # includes workload identity federation via the ANTHROPIC_*
        # env vars (DEVOPS-1019). ANTHROPIC_API_KEY must be unset in the
        # job or it outranks federation in that chain.
        client = Anthropic(default_headers={"anthropic-beta": BETA_HEADER})

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
                  "the session credential belongs to the agent's workspace")

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
    completion_observed = False
    try:
        kwargs: dict = {"agent": agent_id, "environment_id": env.id,
                        "title": f"ai-step {os.environ.get('GITHUB_REPOSITORY', '')}#{run_id}"}
        if vault_id:
            kwargs["vault_ids"] = [vault_id]
        session = client.beta.sessions.create(**kwargs)
        print(f"ai-step: session {session.id} against agent '{agent_name}'")
        sent = client.beta.sessions.events.send(
            session.id,
            events=[{"type": "user.message",
                     "content": [{"type": "text", "text": user_content}]}],
        )
        sent_events = getattr(sent, "data", None) or []
        sent_id = getattr(sent_events[0], "id", None) if sent_events else None
        sent_at = getattr(sent_events[0], "processed_at", None) if sent_events else None
        if not isinstance(sent_at, datetime) or sent_at.tzinfo is None:
            sent_at = None

        deadline = time.time() + timeout_s
        status = "unknown"
        saw_running = False
        idle_event = None
        while time.time() < deadline:
            if sent_at is None and sent_id:
                message = latest_event(client, session.id, "user.message")
                processed_at = getattr(message, "processed_at", None)
                if (getattr(message, "id", None) == sent_id and
                        isinstance(processed_at, datetime) and processed_at.tzinfo is not None):
                    sent_at = processed_at
            status = client.beta.sessions.retrieve(session.id).status
            if status == "running":
                saw_running = True
            elif status == "terminated":
                completion_observed = True
                break
            elif status == "idle":
                idle_event = latest_event(client, session.id, "session.status_idle")
                if saw_running or (idle_event is not None and
                                   event_is_newer_than(idle_event, sent_at)):
                    completion_observed = True
                    break
            time.sleep(POLL_INTERVAL_S)

        if not completion_observed:
            if status == "idle":
                fail_soft("session remained idle without observing startup or a "
                          "newer session.status_idle event")
            fail_soft(f"session still '{status}' after {timeout_s}s — raise "
                      "session-timeout-seconds or pick a faster agent")
        if status == "terminated":
            fail_soft("session terminated before producing output")

        stop = None
        grace_deadline = time.time() + STOP_REASON_GRACE_S
        while True:
            if idle_event is None or not event_is_newer_than(idle_event, sent_at):
                idle_event = latest_event(client, session.id, "session.status_idle")
            fresh_idle = (idle_event is not None and
                          event_is_newer_than(idle_event, sent_at))
            sr = getattr(idle_event, "stop_reason", None) if fresh_idle else None
            stop = sr if isinstance(sr, str) else getattr(sr, "type", None)
            if (stop is not None or time.time() >= grace_deadline):
                break
            time.sleep(POLL_INTERVAL_S)
        if stop != "end_turn":
            recent = [getattr(e, "type", "?") for e in
                      client.beta.sessions.events.list(session.id,
                                                       order="desc", limit=10)]
            fail_soft(f"session stopped with stop_reason '{stop}' instead of "
                      f"end_turn — the agent did not complete its turn "
                      f"(recent events: {recent})")

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
        # Do not remove the environment while a session may still be
        # running. Interrupt active sessions and confirm they stopped before
        # deleting them; retain the environment if cleanup is uncertain.
        delete_session_ok = session is None
        if session is not None:
            # Establish a known stopped state before attempting either delete.
            # If status cannot be read, keep the environment as a safety net.
            try:
                current = client.beta.sessions.retrieve(session.id).status
                interrupted = False
                if current == "running":
                    client.beta.sessions.events.send(
                        session.id, events=[{"type": "user.interrupt"}]
                    )
                    interrupted = True
                    deadline = time.time() + STOP_REASON_GRACE_S
                    while time.time() < deadline:
                        current = client.beta.sessions.retrieve(session.id).status
                        if current != "running":
                            break
                        time.sleep(POLL_INTERVAL_S)
                if (current not in ("idle", "terminated") or
                        (current == "idle" and not completion_observed and
                         not interrupted)):
                    print(f"::warning::ai-step: session {session.id} status "
                          f"'{current}' is not confirmed stopped — keeping environment")
                else:
                    client.beta.sessions.delete(session.id)
                    delete_session_ok = True
                    print(f"ai-step: session {session.id} deleted")
            except Exception as cleanup_error:
                print(f"::warning::ai-step: could not confirm and delete "
                      f"session {session.id}: {cleanup_error} — keeping environment")
        if delete_session_ok:
            try:
                client.beta.environments.delete(env.id)
            except Exception as e:
                print(f"::warning::ai-step: could not delete environment "
                      f"{env.id}: {e} — delete it in the Console")
        else:
            print(f"::warning::ai-step: keeping environment {env.id} because "
                  f"session {session.id} could not be confirmed deleted")


def strip_fence(text: str) -> str:
    """Sessions have no provider-side structured-output binding, and
    agents habitually wrap their JSON in a markdown code fence (observed
    live: sre-memory-curator on the DEVOPS-1352 wif smoke). Strip one
    outer fence when present; anything else is returned as-is."""
    t = text.strip()
    if not t.startswith("```"):
        return t
    parts = t.split("\n", 1)
    if len(parts) != 2 or not parts[1].rstrip().endswith("```"):
        return t
    inner = parts[1].rstrip()
    return inner[: inner.rfind("```")].strip()


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
        if log_output():
            detail = e.message
        else:
            # e.message quotes the offending value, which is agent output;
            # the schema path comes from the caller's schema alone.
            where = "/".join(str(p) for p in e.absolute_schema_path) or "(root)"
            detail = f"fails '{e.validator}' at {where}"
        fail_soft(f"agent output does not validate against output-schema: "
                  f"{detail}", text)
    except jsonschema.SchemaError as e:
        fail_soft(f"output-schema is not a valid JSON Schema: {e.message}")


def main() -> None:
    provider = require("INPUT_PROVIDER")
    mode = os.environ.get("INPUT_MODE", "") or "single"
    prompt = require("INPUT_PROMPT")
    schema_raw = require("INPUT_OUTPUT_SCHEMA")
    input_text = read_input()

    try:
        schema = json.loads(schema_raw)
    except json.JSONDecodeError as e:
        fail_soft(f"output-schema is not valid JSON: {e}")

    user_content = f"{prompt}\n\n{input_text}" if input_text else prompt

    if mode == "session":
        agent_name = require("INPUT_AGENT")
        api_key = os.environ.get("INPUT_ANTHROPIC_SESSION_KEY", "")
        if not api_key and not os.environ.get("ANTHROPIC_FEDERATION_RULE_ID"):
            fail_soft("agent is set but no credential is available — pass "
                      "anthropic-session-key or set up workload identity "
                      "federation in the job env")
        try:
            timeout_s = int(os.environ.get("INPUT_SESSION_TIMEOUT", "1200"))
        except ValueError:
            fail_soft("session-timeout-seconds must be an integer")
        vault_id = os.environ.get("INPUT_VAULT_ID", "").strip()
        text = strip_fence(run_session(agent_name, user_content, api_key,
                                       vault_id, timeout_s))
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            fail_soft("agent returned non-JSON content", text)
        # Session output is validated against the caller's schema as
        # written — enforce_strict is a provider-binding requirement,
        # not part of the caller's contract.
        validate_output(parsed, schema, text)
        emit_result(text)
        emit_kv("conclusion", "success")
        print(f"ai-step: session against '{agent_name}' → success")
        if log_output():
            print(json.dumps(parsed, indent=2))
        return

    model = require("INPUT_MODEL")
    max_tokens = parse_max_tokens(provider)
    enforce_strict(schema)

    if provider == "anthropic":
        api_key = os.environ.get("INPUT_ANTHROPIC_API_KEY", "")
        if not api_key:
            fail_soft("anthropic-api-key required when provider=anthropic")
        text = call_anthropic(model, user_content, schema, api_key, max_tokens)
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

    emit_result(text)
    emit_kv("conclusion", "success")

    print(f"ai-step: {provider} / {model} → success")
    if log_output():
        print(json.dumps(parsed, indent=2))


if __name__ == "__main__":
    main()

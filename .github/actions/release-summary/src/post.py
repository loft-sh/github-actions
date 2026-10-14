#!/usr/bin/env python3
"""Post the rendered release summary as a Slack thread reply, once.

The banner thread is read first. When a reply from an earlier run already
carries the release_summary metadata for this repository and version, that
reply is edited in place with chat.update, so a re-run replaces a thin or
wrong summary and never adds a second one. When the thread cannot be read the
post is skipped: without the lookup a re-run could not be told apart from a
first run.

The action is advisory-only and must never fail the release: every path,
including an unexpected exception, writes its outputs and exits 0, with a
::warning:: where something needs attention. The bot token is never printed
or written; any text that reaches stdout or $GITHUB_OUTPUT has it masked.

Env in:
  SLACK_BOT_TOKEN   bot token; chat:write to post and to edit its own reply,
                    plus channels:history (groups:history for a private
                    channel) to read the thread
  CHANNEL_ID        channel the banner was posted to
  THREAD_TS         banner message ts
  PAYLOAD_FILE      JSON written by render.py, posted as is: {channel,
                    thread_ts, text, blocks, unfurl_links, unfurl_media,
                    metadata: {event_type: "release_summary", event_payload:
                    {repository, version}}}
  SLACK_API_URL     Slack Web API base URL (default: https://slack.com/api)
  RELEASE_SUMMARY_RETRY_SLEEP
                    seconds to wait between attempts, replacing the 2 s and
                    4 s backoff and any Retry-After; set it to 0 in tests
                    and local runs so a dead endpoint fails fast
Env out ($GITHUB_OUTPUT, skipped when unset):
  result            posted | updated | skipped | failed
  reason            one line, empty when posted or updated
  message_ts        ts of the posted or updated reply, empty otherwise

result is skipped when the post was not attempted (a missing input, an
unusable payload, or a thread that could not be read) and failed when it was
attempted and did not land or the payload file could not be read.
"""
from __future__ import annotations

import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import NamedTuple

DEFAULT_API_URL = "https://slack.com/api"
EVENT_TYPE = "release_summary"
TIMEOUT = 20  # seconds per HTTP request
MAX_ATTEMPTS = 3
BACKOFF = (2, 4)  # seconds to wait after the first and the second failure
RETRY_AFTER_CAP = 30  # seconds
MAX_PAGES = 5  # pages of conversations.replies read before giving up
PAGE_SIZE = 200

# Slack errors that say "try again", as opposed to "your request is wrong".
TRANSIENT_ERRORS = frozenset({
    "ratelimited", "internal_error", "service_unavailable",
    "request_timeout", "fatal_error",
})
NETWORK_ERRORS = (OSError, http.client.HTTPException)  # URLError, timeouts, resets

AUTH_ERRORS = ("invalid_auth", "not_authed", "token_revoked", "account_inactive")
AUTH_REMEDY = "check that slack-bot-token is a valid bot token"
CHANNEL_REMEDY = "check the channel id, and invite the bot if the channel is private"
READ_REMEDIES = {
    **dict.fromkeys(AUTH_ERRORS, AUTH_REMEDY),
    "missing_scope": ("the bot needs channels:history (groups:history for a "
                      "private channel) so a re-run cannot post twice"),
    "not_in_channel": "invite the bot to the channel so it can read the thread",
    "channel_not_found": CHANNEL_REMEDY,
    "thread_not_found": "check that THREAD_TS is the banner's message ts",
}
DEFAULT_READ_REMEDY = "nothing was posted, so a re-run cannot post twice"
POST_REMEDIES = {
    **dict.fromkeys(AUTH_ERRORS, AUTH_REMEDY),
    "missing_scope": "the bot needs the chat:write scope",
    "not_in_channel": "invite the bot to the channel",
    "channel_not_found": CHANNEL_REMEDY,
}
DELETE_REMEDY = "delete the old summary in Slack and re-run to post a fresh one"
UPDATE_REMEDIES = {
    **POST_REMEDIES,
    "cant_update_message": ("the old summary was posted by another app; "
                            + DELETE_REMEDY),
    "edit_window_closed": "the workspace no longer allows editing it; " + DELETE_REMEDY,
    "message_not_found": "the old summary was deleted while this ran; re-run to post",
}


class Outcome(NamedTuple):
    result: str  # posted | updated | skipped | failed
    reason: str = ""
    message_ts: str = ""


class Stop(Exception):
    """End the run early with a known outcome."""

    def __init__(self, result: str, reason: str):
        super().__init__(reason)
        self.outcome = Outcome(result, reason)

# Failures Slack rejected before acting on the request.
RATE_LIMITED = {"http_429", "ratelimited"}


def warn(msg: str) -> None:
    # Collapse whitespace so a newline in msg can never start a second
    # workflow command.
    print(f"::warning::release-summary: {' '.join(str(msg).split())}")


def info(msg: str) -> None:
    print(f"release-summary: {msg}")


def emit(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{key}={' '.join(str(value).split())}\n")
    except OSError as e:
        warn(f"could not write output {key}: {e}")


def env(name: str) -> str:
    return os.environ.get(name, "").strip()


def redact(text: str, token: str) -> str:
    """Mask the bot token in text that is about to be printed or written."""
    return text.replace(token, "***") if token else text


def pause(seconds: float) -> None:
    """Sleep between attempts. Tests stub this function; the env var
    RELEASE_SUMMARY_RETRY_SLEEP replaces the wait with a fixed number."""
    override = env("RELEASE_SUMMARY_RETRY_SLEEP")
    if override:
        try:
            value = float(override)
        except ValueError:
            value = -1.0
        if value >= 0:
            seconds = value
    time.sleep(seconds)


def api_url() -> str:
    return env("SLACK_API_URL").rstrip("/") or DEFAULT_API_URL


def error_of(resp: dict) -> str:
    """The Slack error code of a failed response, always a non-empty string."""
    error = resp.get("error")
    return error if isinstance(error, str) and error else "unknown_error"


def parse(body: bytes) -> dict:
    try:
        data = json.loads(body)
    except ValueError:
        return {"ok": False, "error": "invalid_response"}
    return data if isinstance(data, dict) else {"ok": False, "error": "invalid_response"}


def retry_after(err: urllib.error.HTTPError) -> float | None:
    """Seconds named by a Retry-After header, capped, or None."""
    try:
        seconds = float(err.headers.get("Retry-After"))
    except (AttributeError, TypeError, ValueError):
        return None
    return min(seconds, RETRY_AFTER_CAP) if seconds >= 0 else None


def send(req: urllib.request.Request) -> tuple[dict, bool, float | None]:
    """One HTTP exchange. Returns (response, retryable, Retry-After seconds).
    Every failure comes back as {"ok": False, "error": ...}; nothing raises."""
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = parse(resp.read())
    except urllib.error.HTTPError as e:
        retryable = e.code == 429 or e.code >= 500
        wait = retry_after(e) if e.code == 429 else None
        return {"ok": False, "error": f"http_{e.code}"}, retryable, wait
    except NETWORK_ERRORS as e:
        name = type(getattr(e, "reason", e)).__name__
        return {"ok": False, "error": f"network_error ({name})"}, True, None
    retryable = data.get("ok") is not True and error_of(data) in TRANSIENT_ERRORS
    return data, retryable, None


def call(endpoint: str, token: str, params: dict | None = None,
         payload: dict | None = None, only_rate_limits: bool = False) -> dict:
    """Every Slack call goes through here: GET with a query, or POST with a
    JSON body. Up to MAX_ATTEMPTS tries on transient failures, then the last
    failure as {"ok": False, "error": ...}. only_rate_limits retries only
    failures Slack rejected before acting (HTTP 429, ratelimited), for calls
    that must not run twice: a timeout or 5xx may follow a post that landed."""
    url = f"{api_url()}/{endpoint}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    method = "GET" if data is None else "POST"
    last: dict = {"ok": False, "error": "no_attempt"}
    for attempt in range(MAX_ATTEMPTS):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        last, retryable, wait = send(req)
        if only_rate_limits:
            retryable = retryable and error_of(last) in RATE_LIMITED
        if not retryable:
            return last
        if attempt + 1 < MAX_ATTEMPTS:
            pause(BACKOFF[attempt] if wait is None else wait)
    return last


def summary_key(metadata) -> tuple[str, str] | None:
    """(repository, version) of a release_summary metadata block, else None."""
    if not isinstance(metadata, dict) or metadata.get("event_type") != EVENT_TYPE:
        return None
    body = metadata.get("event_payload")
    if not isinstance(body, dict):
        return None
    repository, version = body.get("repository"), body.get("version")
    if (isinstance(repository, str) and repository
            and isinstance(version, str) and version):
        return repository, version
    return None


def load_payload(path: str, channel: str, thread_ts: str) -> dict:
    """The payload render.py wrote. Stops with failed when the file cannot be
    read, and with skipped when it is not a usable release summary payload."""
    if not path:
        raise Stop("failed", "PAYLOAD_FILE is not set, so there is no summary to post")
    try:
        with open(path, encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, ValueError) as e:
        raise Stop("failed", f"payload file could not be read: {e}")
    if not isinstance(payload, dict):
        raise Stop("skipped", "payload file is not a JSON object")
    if summary_key(payload.get("metadata")) is None:
        raise Stop("skipped", "payload has no release_summary metadata with a "
                   "repository and version, so a duplicate could not be detected")
    for key, name, want in (("channel", "CHANNEL_ID", channel),
                            ("thread_ts", "THREAD_TS", thread_ts)):
        if payload.get(key) != want:
            raise Stop("skipped", f"payload {key} {payload.get(key)!r} differs "
                       f"from {name}; render and post must use the same value")
    return payload


def thread_failure(error: str) -> Stop:
    remedy = READ_REMEDIES.get(error, DEFAULT_READ_REMEDY)
    return Stop("skipped", f"could not read the banner thread ({error}); {remedy}")


def next_cursor(resp: dict) -> str:
    meta = resp.get("response_metadata")
    cursor = meta.get("next_cursor") if isinstance(meta, dict) else ""
    return cursor if isinstance(cursor, str) else ""


def find_existing(token: str, channel: str, thread_ts: str,
                  key: tuple[str, str]) -> str | None:
    """ts of a reply that already carries this summary's metadata, or None
    when the whole thread was read without finding one. Stops with skipped
    when the thread cannot be read in full."""
    cursor = ""
    for _ in range(MAX_PAGES):
        params = {"channel": channel, "ts": thread_ts,
                  "include_all_metadata": "true", "limit": PAGE_SIZE}
        if cursor:
            params["cursor"] = cursor
        resp = call("conversations.replies", token, params=params)
        if resp.get("ok") is not True:
            raise thread_failure(error_of(resp))
        messages = resp.get("messages")
        for msg in messages if isinstance(messages, list) else []:
            if isinstance(msg, dict) and summary_key(msg.get("metadata")) == key:
                return str(msg.get("ts") or "")
        cursor = next_cursor(resp)
        if not cursor:
            return None
    raise Stop("skipped", f"the banner thread has more than {MAX_PAGES * PAGE_SIZE} "
               "replies, so a summary already in it could be missed; nothing was "
               "posted, so a re-run cannot post twice")


def failure(method: str, resp: dict, remedies: dict) -> Outcome:
    error = error_of(resp)
    remedy = remedies.get(error)
    reason = f"{method} failed ({error})"
    return Outcome("failed", f"{reason}; {remedy}" if remedy else reason)


def post(token: str, payload: dict) -> Outcome:
    resp = call("chat.postMessage", token, payload=payload, only_rate_limits=True)
    if resp.get("ok") is True:
        return Outcome("posted", "", str(resp.get("ts") or ""))
    return failure("chat.postMessage", resp, POST_REMEDIES)


def update(token: str, payload: dict, ts: str) -> Outcome:
    """Replace the text of the summary an earlier run posted. Unlike a post,
    an edit is safe to retry on any transient failure: running it twice
    leaves the same message."""
    body = {"channel": payload["channel"], "ts": ts, "text": payload.get("text", ""),
            "blocks": payload.get("blocks", []), "metadata": payload["metadata"]}
    resp = call("chat.update", token, payload=body)
    if resp.get("ok") is True:
        return Outcome("updated", "", ts)
    return failure("chat.update", resp, UPDATE_REMEDIES)


def deliver(token: str) -> Outcome:
    channel, thread_ts = env("CHANNEL_ID"), env("THREAD_TS")
    if not token:
        raise Stop("skipped", "no Slack bot token; pass slack-bot-token to post "
                   "the summary")
    if not channel:
        raise Stop("skipped", "no Slack channel id; pass the channel the banner "
                   "was posted to")
    if not thread_ts:
        raise Stop("skipped", "no banner message ts, so there is no thread to "
                   "reply in; check that the bot token post succeeded in the "
                   "notify job")
    payload = load_payload(env("PAYLOAD_FILE"), channel, thread_ts)
    key = summary_key(payload["metadata"])
    existing = find_existing(token, channel, thread_ts, key)
    if existing:
        return update(token, payload, existing)
    return post(token, payload)


def run(token: str) -> Outcome:
    try:
        return deliver(token)
    except Stop as stop:
        return stop.outcome


def report(outcome: Outcome, token: str) -> None:
    """Print the outcome and write it to $GITHUB_OUTPUT, token masked."""
    def clean(text: str) -> str:
        return redact(" ".join(str(text).split()), token)

    result, reason, ts = outcome.result, clean(outcome.reason), clean(outcome.message_ts)
    if result in ("skipped", "failed"):
        warn(reason)
    elif result == "updated":
        info(f"replaced the summary already in the thread (ts {ts})")
    else:
        info(f"posted the summary as a thread reply (ts {ts})")
    emit("result", result)
    emit("reason", reason)
    emit("message_ts", ts)


def main() -> None:
    token = env("SLACK_BOT_TOKEN")
    try:
        outcome = run(token)
    except Exception as e:  # advisory-only: nothing may fail the release
        outcome = Outcome("failed", f"unexpected {type(e).__name__}: {e}")
    report(outcome, token)


if __name__ == "__main__":
    main()
    sys.exit(0)

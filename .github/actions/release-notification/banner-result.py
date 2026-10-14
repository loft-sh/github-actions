#!/usr/bin/env python3
"""Decide whether the bot token banner landed, and whether the webhook
should post it instead.

The bot post runs with retries off, because a resend after a timeout or a
5xx can duplicate a banner that already landed. Its outcome then falls in
one of three cases:

  ok                  posted; expose its ts for thread replies
  rejected by Slack   Slack refused before acting (not_in_channel,
                      invalid_auth, ...): fall back to the webhook
  ambiguous           a timeout, a 5xx, internal_error, or no response at
                      all: the banner may or may not be in the channel

An ambiguous outcome is settled by reading the channel for a message that
carries this banner's release_banner metadata. Found: it posted, no
fallback. Not found, or the channel cannot be read: fall back to the
webhook, so the worst case is a rare duplicate banner, never a silent
missing one.

Env in:
  POST_OK          ok output of the bot post step ("true" when it posted)
  POST_RESPONSE    response output of the bot post step (JSON, may be empty)
  POST_TS          ts output of the bot post step
  SLACK_BOT_TOKEN  bot token; channels:history (groups:history for a
                   private channel) lets it settle an ambiguous outcome
  CHANNEL_ID       channel the banner was posted to
  REPOSITORY       repository in the banner metadata
  VERSION          version in the banner metadata
  HAS_WEBHOOK      "true" when a webhook can post the banner instead
  SLACK_API_URL    Slack Web API base URL (default: https://slack.com/api)
  BANNER_CHECK_DELAY
                   seconds to wait before reading the channel (default 5),
                   so a post that landed as the request timed out shows up
Env out ($GITHUB_OUTPUT):
  posted           true | false
  ts               banner ts when posted, else empty
  channel_id       channel id when posted, else empty
  fallback         true when the webhook should post the banner

Exits 1 only when the banner did not post and there is no webhook to fall
back on, which is how the webhook-only path has always failed.
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

DEFAULT_API_URL = "https://slack.com/api"
EVENT_TYPE = "release_banner"
TIMEOUT = 20  # seconds per HTTP request
LOOKBACK = 900  # seconds of channel history searched for the banner
HISTORY_LIMIT = 100
NETWORK_ERRORS = (OSError, http.client.HTTPException)

# Slack error codes returned without saying whether the message was stored.
AMBIGUOUS_ERRORS = frozenset({
    "internal_error", "fatal_error", "request_timeout", "service_unavailable",
})
AUTH_REMEDY = "check that slack_bot_token is a valid bot token"
REMEDIES = {
    **dict.fromkeys(("invalid_auth", "not_authed", "token_revoked",
                     "account_inactive"), AUTH_REMEDY),
    "not_in_channel": "invite the bot to the channel",
    "channel_not_found": "check slack_channel_id, and invite the bot if the channel is private",
    "missing_scope": "the bot needs the chat:write scope",
    "is_archived": "the channel is archived",
}


def env(name: str) -> str:
    return os.environ.get(name, "").strip()


def clean(text: str) -> str:
    """One line, token masked: everything printed or written goes through here."""
    text = " ".join(str(text).split())
    token = env("SLACK_BOT_TOKEN")
    return text.replace(token, "***") if token else text


def emit(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{key}={clean(value)}\n")
    except OSError as e:
        print(f"::warning::could not write output {key}: {e}")


def rejection(response: str) -> str | None:
    """The Slack error code when Slack refused the post before acting, else
    None for an ambiguous outcome."""
    try:
        data = json.loads(response)
    except ValueError:
        return None
    if not isinstance(data, dict) or data.get("ok") is not False:
        return None
    error = data.get("error")
    if not isinstance(error, str) or not error or error in AMBIGUOUS_ERRORS:
        return None
    return error


def history(token: str, channel: str, oldest: float) -> dict:
    """conversations.history since oldest, as a dict; never raises."""
    query = urllib.parse.urlencode({"channel": channel, "oldest": f"{oldest:.6f}",
                                    "limit": HISTORY_LIMIT, "include_all_metadata": "true"})
    url = f"{env('SLACK_API_URL').rstrip('/') or DEFAULT_API_URL}/conversations.history?{query}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"http_{e.code}"}
    except NETWORK_ERRORS as e:
        return {"ok": False, "error": f"network_error ({type(getattr(e, 'reason', e)).__name__})"}
    except ValueError:
        return {"ok": False, "error": "invalid_response"}
    return data if isinstance(data, dict) else {"ok": False, "error": "invalid_response"}


def find_banner(token: str, channel: str, repository: str, version: str) -> tuple[str | None, str]:
    """(ts of the banner, "") when it is in the channel, (None, "") when it
    is not, (None, error) when the channel could not be read."""
    delay = env("BANNER_CHECK_DELAY")
    time.sleep(float(delay) if delay.replace(".", "", 1).isdigit() else 5)
    resp = history(token, channel, time.time() - LOOKBACK)
    if resp.get("ok") is not True:
        error = resp.get("error")
        return None, error if isinstance(error, str) and error else "unknown_error"
    messages = resp.get("messages")
    for msg in messages if isinstance(messages, list) else []:
        meta = msg.get("metadata") if isinstance(msg, dict) else None
        if not isinstance(meta, dict) or meta.get("event_type") != EVENT_TYPE:
            continue
        body = meta.get("event_payload")
        if isinstance(body, dict) and body.get("repository") == repository \
                and body.get("version") == version and msg.get("ts"):
            return str(msg["ts"]), ""
    return None, ""


def decide() -> tuple[bool, str, str]:
    """(posted, ts, reason the banner did not post)."""
    if env("POST_OK") == "true" and env("POST_TS"):
        return True, env("POST_TS"), ""
    response = env("POST_RESPONSE")
    error = rejection(response)
    if error:
        remedy = REMEDIES.get(error)
        return False, "", f"Slack rejected the bot token banner ({error})" + (f"; {remedy}" if remedy else "")
    channel = env("CHANNEL_ID")
    ts, lookup_error = find_banner(env("SLACK_BOT_TOKEN"), channel,
                                   env("REPOSITORY"), env("VERSION"))
    if ts:
        print(f"release-notification: the bot post reported no success "
              f"({clean(response) or 'no response'}), but the banner is in the channel (ts {ts})")
        return True, ts, ""
    if lookup_error:
        return False, "", (f"the bot token post ended without a clear result "
                           f"({clean(response) or 'no response'}) and the channel could not be "
                           f"read to check it ({lookup_error}; the bot needs channels:history); "
                           "a webhook fallback may duplicate the banner")
    return False, "", (f"the bot token post ended without a clear result "
                       f"({clean(response) or 'no response'}) and the banner is not in the channel")


def main() -> int:
    try:
        posted, ts, reason = decide()
    except Exception as e:  # an unexpected failure must not skip the fallback
        posted, ts, reason = False, "", f"checking the bot token post failed: {type(e).__name__}: {e}"
    has_webhook = env("HAS_WEBHOOK") == "true"
    emit("posted", "true" if posted else "false")
    emit("ts", ts)
    emit("channel_id", env("CHANNEL_ID") if posted else "")
    emit("fallback", "true" if not posted and has_webhook else "false")
    if posted:
        return 0
    if has_webhook:
        print(f"::warning::{clean(reason)}. Falling back to the webhook; the banner gets no thread reply.")
        return 0
    print(f"::error::{clean(reason)}. No webhook_url is set to fall back on.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

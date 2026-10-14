"""post.py: the idempotent thread reply, retries, and the never-fail contract.
A scripted Slack Web API runs on a loopback port, so the real urllib path is
exercised (headers, query encoding, Retry-After) with no network and no real
token. The retry sleep is stubbed."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "post.py"

TOKEN = "xoxb-test-secret-0123456789"
CHANNEL = "C0123ABCD"
THREAD = "1700000000.000100"
REPO = "loft-sh/vcluster-pro"
VERSION = "v1.2.3"
BANNER = {"type": "message", "ts": THREAD, "text": "banner"}
REPLIES = "conversations.replies"
POST = "chat.postMessage"


def load():
    spec = importlib.util.spec_from_file_location("release_summary_post", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def mod():
    """A fresh module whose sleep is replaced by a recorder (mod.slept)."""
    m = load()
    m.slept = []
    m.pause = m.slept.append
    return m


class FakeSlack:
    """Scripted Slack Web API. queue() adds responses for an endpoint: a dict
    is an HTTP 200 JSON body, bytes is a raw 200 body, a tuple is
    (status, body, headers). Every request is recorded."""

    def __init__(self):
        self.script: dict[str, list] = {}
        self.requests: list[dict] = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.url = f"http://127.0.0.1:{self.server.server_port}/api"
        # a short poll interval keeps shutdown() from adding half a second per test
        threading.Thread(target=self.server.serve_forever, args=(0.01,), daemon=True).start()

    def queue(self, endpoint: str, *responses) -> None:
        self.script.setdefault(endpoint, []).extend(responses)

    def calls(self, endpoint: str) -> list[dict]:
        return [r for r in self.requests if r["endpoint"] == endpoint]

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def _handler(self):
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def serve(self):
                parsed = urllib.parse.urlsplit(self.path)
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length).decode() if length else ""
                endpoint = parsed.path.rsplit("/", 1)[-1]
                outer.requests.append({
                    "method": self.command,
                    "path": parsed.path,
                    "endpoint": endpoint,
                    "query": urllib.parse.parse_qs(parsed.query),
                    "headers": {k.lower(): v for k, v in self.headers.items()},
                    "body": json.loads(body) if body else None,
                })
                queue = outer.script.get(endpoint) or []
                reply = queue.pop(0) if queue else (418, {"ok": False, "error": "unscripted"}, {})
                status, payload, headers = reply if isinstance(reply, tuple) else (200, reply, {})
                data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(data)

            do_GET = do_POST = serve

        return Handler


def make_payload(version=VERSION, repository=REPO, **overrides) -> dict:
    payload = {
        "channel": CHANNEL,
        "thread_ts": THREAD,
        "text": f"What changed in {version} since v1.2.2",
        "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": "Café … done"}}],
        "unfurl_links": False,
        "unfurl_media": False,
        "metadata": {"event_type": "release_summary",
                     "event_payload": {"repository": repository, "version": version}},
    }
    payload.update(overrides)
    return payload


@pytest.fixture
def env(tmp_path, monkeypatch):
    """Inputs for a normal run. SLACK_API_URL points at a closed port, so a
    test that forgets the slack fixture cannot reach the real Slack."""
    out = tmp_path / "github_output"
    out.write_text("")
    payload_file = tmp_path / "payload.json"
    payload_file.write_text(json.dumps(make_payload()))
    for key, value in {"GITHUB_OUTPUT": str(out), "SLACK_BOT_TOKEN": TOKEN,
                       "CHANNEL_ID": CHANNEL, "THREAD_TS": THREAD,
                       "PAYLOAD_FILE": str(payload_file),
                       "SLACK_API_URL": "http://127.0.0.1:9",
                       "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"}.items():
        monkeypatch.setenv(key, value)
    monkeypatch.delenv("RELEASE_SUMMARY_RETRY_SLEEP", raising=False)
    return out


@pytest.fixture
def slack(env, monkeypatch):
    fake = FakeSlack()
    monkeypatch.setenv("SLACK_API_URL", fake.url)
    yield fake
    fake.close()


def outputs(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)


def run_main(mod, env) -> dict[str, str]:
    mod.main()
    return outputs(env)


def page(*messages, cursor: str = "") -> dict:
    return {"ok": True, "messages": list(messages), "has_more": bool(cursor),
            "response_metadata": {"next_cursor": cursor}}


def summary_msg(ts: str, version=VERSION, repository=REPO, event_type="release_summary") -> dict:
    return {"type": "message", "ts": ts, "thread_ts": THREAD, "text": "summary",
            "metadata": {"event_type": event_type,
                         "event_payload": {"repository": repository, "version": version}}}


# posting

def test_posts_when_thread_has_no_summary(mod, slack, env, capsys):
    slack.queue(REPLIES, page(BANNER))
    slack.queue(POST, {"ok": True, "ts": "1700000001.000200"})
    o = run_main(mod, env)
    assert o == {"result": "posted", "reason": "", "message_ts": "1700000001.000200"}
    read, write = slack.requests
    assert (read["method"], read["path"]) == ("GET", f"/api/{REPLIES}")
    assert read["query"] == {"channel": [CHANNEL], "ts": [THREAD],
                             "include_all_metadata": ["true"], "limit": ["200"]}
    assert (write["method"], write["path"]) == ("POST", f"/api/{POST}")
    assert write["body"] == make_payload()
    assert write["headers"]["content-type"] == "application/json; charset=utf-8"
    assert all(r["headers"]["authorization"] == f"Bearer {TOKEN}" for r in slack.requests)
    out = capsys.readouterr().out
    assert "::warning::" not in out
    assert TOKEN not in out and TOKEN not in env.read_text()
    assert mod.slept == []


@pytest.mark.parametrize("version,repository", [
    ("v1.2.2", REPO),
    (VERSION, "loft-sh/loft-enterprise"),
])
def test_summary_for_another_release_does_not_block(mod, slack, env, version, repository):
    slack.queue(REPLIES, page(BANNER, summary_msg("1700000002.000100", version, repository)))
    slack.queue(POST, {"ok": True, "ts": "1700000003.000100"})
    assert run_main(mod, env)["result"] == "posted"
    assert len(slack.calls(POST)) == 1


def test_other_metadata_and_plain_replies_do_not_block(mod, slack, env):
    slack.queue(REPLIES, page(
        BANNER,
        {"ts": "1700000002.000100", "text": "thanks!"},
        summary_msg("1700000002.000200", event_type="deploy_notice"),
        {"ts": "1700000002.000300", "metadata": "not-a-dict"},
    ))
    slack.queue(POST, {"ok": True, "ts": "1700000003.000100"})
    assert run_main(mod, env)["result"] == "posted"


# idempotency

def test_exists_when_matching_reply_is_in_the_thread(mod, slack, env, capsys):
    slack.queue(REPLIES, page(BANNER, summary_msg("1700000005.000300")))
    o = run_main(mod, env)
    assert o == {"result": "exists", "message_ts": "1700000005.000300",
                 "reason": f"a summary for {VERSION} is already in this thread"}
    assert slack.calls(POST) == []
    out = capsys.readouterr().out
    assert "already in this thread" in out
    assert "::warning::" not in out


def test_match_on_second_page(mod, slack, env):
    cursor = "dGVhbTpDMDYx=="
    slack.queue(REPLIES, page(BANNER, cursor=cursor), page(summary_msg("1700000009.000900")))
    o = run_main(mod, env)
    assert (o["result"], o["message_ts"]) == ("exists", "1700000009.000900")
    first, second = slack.calls(REPLIES)
    assert "cursor" not in first["query"]
    assert second["query"]["cursor"] == [cursor]
    assert slack.calls(POST) == []


def test_match_on_first_page_stops_paging(mod, slack, env):
    slack.queue(REPLIES, page(summary_msg("1700000005.000300"), cursor="more"))
    assert run_main(mod, env)["result"] == "exists"
    assert len(slack.calls(REPLIES)) == 1


def test_thread_longer_than_the_page_cap_is_skipped(mod, slack, env):
    slack.queue(REPLIES, *[page(BANNER, cursor=f"c{i}") for i in range(10)])
    o = run_main(mod, env)
    assert o["result"] == "skipped"
    assert "1000" in o["reason"]
    assert len(slack.calls(REPLIES)) == 5
    assert slack.calls(POST) == []


# lookup failures never post

def test_missing_scope_on_lookup_skips_with_remedy(mod, slack, env, capsys):
    slack.queue(REPLIES, {"ok": False, "error": "missing_scope", "needed": "channels:history"})
    o = run_main(mod, env)
    assert o["result"] == "skipped"
    assert o["reason"].startswith("could not read the banner thread (missing_scope);")
    assert "channels:history" in o["reason"] and "groups:history" in o["reason"]
    assert "::warning::release-summary: could not read the banner thread" in capsys.readouterr().out
    assert slack.calls(POST) == []
    assert o["message_ts"] == ""


@pytest.mark.parametrize("error,remedy", [
    ("not_in_channel", "invite the bot"),
    ("channel_not_found", "channel id"),
    ("invalid_auth", "slack-bot-token"),
    ("thread_not_found", "THREAD_TS"),
    ("something_new", "nothing was posted"),
])
def test_other_lookup_errors_skip_with_remedy(mod, slack, env, error, remedy):
    slack.queue(REPLIES, {"ok": False, "error": error})
    o = run_main(mod, env)
    assert o["result"] == "skipped"
    assert f"({error})" in o["reason"] and remedy in o["reason"]
    assert slack.calls(POST) == []


def test_unreachable_slack_skips_after_three_attempts(mod, env, capsys):
    o = run_main(mod, env)
    assert o["result"] == "skipped"
    assert "could not read the banner thread (network_error" in o["reason"]
    assert mod.slept == [2, 4]
    assert "::warning::" in capsys.readouterr().out


# retries

def test_server_error_is_retried(mod, slack, env):
    slack.queue(REPLIES, (500, {"ok": False, "error": "boom"}, {}), page(BANNER))
    slack.queue(POST, {"ok": True, "ts": "1700000001.000200"})
    assert run_main(mod, env)["result"] == "posted"
    assert len(slack.calls(REPLIES)) == 2
    assert mod.slept == [2]


def test_backoff_doubles_on_the_second_retry(mod, slack, env):
    slack.queue(REPLIES, (503, {}, {}), (502, {}, {}), page(BANNER))
    slack.queue(POST, {"ok": True, "ts": "1700000001.000200"})
    assert run_main(mod, env)["result"] == "posted"
    assert mod.slept == [2, 4]


def test_429_honors_retry_after(mod, slack, env):
    slack.queue(REPLIES, (429, {"ok": False, "error": "ratelimited"}, {"Retry-After": "7"}),
                page(BANNER))
    slack.queue(POST, {"ok": True, "ts": "1700000001.000200"})
    assert run_main(mod, env)["result"] == "posted"
    assert mod.slept == [7]


def test_429_retry_after_is_capped(mod, slack, env):
    slack.queue(REPLIES, (429, {"ok": False, "error": "ratelimited"}, {"Retry-After": "120"}),
                page(BANNER))
    slack.queue(POST, {"ok": True, "ts": "1700000001.000200"})
    assert run_main(mod, env)["result"] == "posted"
    assert mod.slept == [30]


def test_429_without_a_usable_retry_after_uses_the_backoff(mod, slack, env):
    slack.queue(REPLIES, (429, {}, {"Retry-After": "soon"}), (429, {}, {}), page(BANNER))
    slack.queue(POST, {"ok": True, "ts": "1700000001.000200"})
    assert run_main(mod, env)["result"] == "posted"
    assert mod.slept == [2, 4]


@pytest.mark.parametrize("error", ["internal_error", "service_unavailable",
                                   "request_timeout", "fatal_error"])
def test_transient_lookup_error_is_retried(mod, slack, env, error):
    slack.queue(REPLIES, {"ok": False, "error": error}, page(BANNER))
    slack.queue(POST, {"ok": True, "ts": "1700000001.000200"})
    assert run_main(mod, env)["result"] == "posted"
    assert len(slack.calls(REPLIES)) == 2
    assert mod.slept == [2]


def test_rate_limited_post_is_retried(mod, slack, env):
    slack.queue(REPLIES, page(BANNER))
    slack.queue(POST, {"ok": False, "error": "ratelimited"}, {"ok": True, "ts": "1700000001.000200"})
    o = run_main(mod, env)
    assert (o["result"], o["message_ts"]) == ("posted", "1700000001.000200")
    assert len(slack.calls(POST)) == 2
    assert mod.slept == [2]


def test_http_429_post_is_retried(mod, slack, env):
    slack.queue(REPLIES, page(BANNER))
    slack.queue(POST, (429, {"ok": False, "error": "ratelimited"}, {"Retry-After": "3"}),
                {"ok": True, "ts": "1700000001.000200"})
    assert run_main(mod, env)["result"] == "posted"
    assert mod.slept == [3]


@pytest.mark.parametrize("failure", [
    (500, {"ok": False, "error": "boom"}, {}),
    {"ok": False, "error": "internal_error"},
    {"ok": False, "error": "request_timeout"},
])
def test_ambiguous_post_failure_is_not_retried(mod, slack, env, failure):
    """A 5xx or a timeout may follow a post that landed, so a retry could
    put a second summary in the thread. Skip instead."""
    slack.queue(REPLIES, page(BANNER))
    slack.queue(POST, failure, {"ok": True, "ts": "1700000001.000200"})
    o = run_main(mod, env)
    assert o["result"] == "failed"
    assert len(slack.calls(POST)) == 1
    assert mod.slept == []


def test_rate_limited_post_gives_up_after_three_attempts(mod, slack, env):
    slack.queue(REPLIES, page(BANNER))
    slack.queue(POST, *[{"ok": False, "error": "ratelimited"}] * 3)
    o = run_main(mod, env)
    assert o["result"] == "failed"
    assert "ratelimited" in o["reason"]
    assert len(slack.calls(POST)) == 3
    assert mod.slept == [2, 4]


def test_client_error_is_not_retried(mod, slack, env):
    slack.queue("x", (404, {"ok": False}, {}))
    assert mod.call("x", TOKEN) == {"ok": False, "error": "http_404"}
    assert len(slack.requests) == 1 and mod.slept == []


def test_non_json_body_is_a_failure_not_a_crash(mod, slack, env):
    slack.queue("x", b"<html>bad gateway</html>")
    assert mod.call("x", TOKEN) == {"ok": False, "error": "invalid_response"}
    assert len(slack.requests) == 1


def test_call_returns_the_last_network_error(mod, env):
    resp = mod.call("x", TOKEN)
    assert resp["ok"] is False and resp["error"].startswith("network_error")
    assert mod.slept == [2, 4]


def test_pause_honors_the_env_override(monkeypatch):
    mod = load()
    naps = []
    monkeypatch.setattr(mod.time, "sleep", naps.append)
    mod.pause(4)
    monkeypatch.setenv("RELEASE_SUMMARY_RETRY_SLEEP", "0.5")
    mod.pause(4)
    monkeypatch.setenv("RELEASE_SUMMARY_RETRY_SLEEP", "junk")
    mod.pause(4)
    assert naps == [4, 0.5, 4]


# post failures

@pytest.mark.parametrize("error,remedy", [
    ("not_in_channel", "invite the bot"),
    ("channel_not_found", "channel id"),
    ("missing_scope", "chat:write"),
    ("invalid_auth", "slack-bot-token"),
    ("not_authed", "slack-bot-token"),
])
def test_post_failure_names_the_remedy(mod, slack, env, capsys, error, remedy):
    slack.queue(REPLIES, page(BANNER))
    slack.queue(POST, {"ok": False, "error": error})
    o = run_main(mod, env)
    assert o["result"] == "failed" and o["message_ts"] == ""
    assert o["reason"].startswith(f"chat.postMessage failed ({error});")
    assert remedy in o["reason"]
    assert "::warning::release-summary: chat.postMessage failed" in capsys.readouterr().out
    assert len(slack.calls(POST)) == 1 and mod.slept == []


def test_post_failure_without_a_known_remedy(mod, slack, env):
    slack.queue(REPLIES, page(BANNER))
    slack.queue(POST, {"ok": False, "error": "msg_too_long"})
    o = run_main(mod, env)
    assert (o["result"], o["reason"]) == ("failed", "chat.postMessage failed (msg_too_long)")


# inputs

@pytest.mark.parametrize("name,needle", [
    ("SLACK_BOT_TOKEN", "slack-bot-token"),
    ("CHANNEL_ID", "channel id"),
    ("THREAD_TS", "no thread"),
])
def test_missing_input_skips_without_calling_slack(mod, slack, env, monkeypatch, name, needle):
    monkeypatch.setenv(name, "")
    o = run_main(mod, env)
    assert o["result"] == "skipped" and needle in o["reason"]
    assert slack.requests == []


def test_unreadable_payload_fails(mod, slack, env, monkeypatch, tmp_path):
    monkeypatch.setenv("PAYLOAD_FILE", str(tmp_path / "missing.json"))
    o = run_main(mod, env)
    assert o["result"] == "failed" and "payload file could not be read" in o["reason"]
    assert slack.requests == []


def test_unset_payload_path_fails(mod, slack, env, monkeypatch):
    monkeypatch.delenv("PAYLOAD_FILE")
    assert run_main(mod, env)["result"] == "failed"
    assert slack.requests == []


def test_payload_that_is_not_json_fails(mod, slack, env, monkeypatch, tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    monkeypatch.setenv("PAYLOAD_FILE", str(bad))
    assert run_main(mod, env)["result"] == "failed"
    assert slack.requests == []


@pytest.mark.parametrize("doc", [
    [],
    {},
    make_payload(metadata={"event_type": "other", "event_payload": {"repository": REPO, "version": VERSION}}),
    make_payload(metadata={"event_type": "release_summary", "event_payload": {"repository": REPO}}),
    make_payload(metadata={"event_type": "release_summary", "event_payload": {"repository": "", "version": VERSION}}),
    make_payload(metadata="release_summary"),
])
def test_payload_without_summary_metadata_skips(mod, slack, env, monkeypatch, tmp_path, doc):
    f = tmp_path / "odd.json"
    f.write_text(json.dumps(doc))
    monkeypatch.setenv("PAYLOAD_FILE", str(f))
    assert run_main(mod, env)["result"] == "skipped"
    assert slack.requests == []


@pytest.mark.parametrize("key,value,name", [("channel", "C999", "CHANNEL_ID"),
                                            ("thread_ts", "1.2", "THREAD_TS")])
def test_payload_for_another_thread_skips(mod, slack, env, monkeypatch, tmp_path, key, value, name):
    f = tmp_path / "other.json"
    f.write_text(json.dumps(make_payload(**{key: value})))
    monkeypatch.setenv("PAYLOAD_FILE", str(f))
    o = run_main(mod, env)
    assert o["result"] == "skipped" and name in o["reason"]
    assert slack.requests == []


# never fail, never leak

def test_token_is_masked_when_slack_echoes_it(mod, slack, env, capsys):
    slack.queue(REPLIES, page(BANNER))
    slack.queue(POST, {"ok": False, "error": f"bad token {TOKEN}"})
    o = run_main(mod, env)
    seen = capsys.readouterr()
    assert o["result"] == "failed" and "***" in o["reason"]
    assert TOKEN not in seen.out + seen.err
    assert TOKEN not in env.read_text()


def test_unexpected_exception_fails_soft_and_masks_the_token(mod, env, monkeypatch, capsys):
    def boom(token):
        raise RuntimeError(f"exploded with {token}")

    monkeypatch.setattr(mod, "deliver", boom)
    o = run_main(mod, env)
    seen = capsys.readouterr()
    assert o["result"] == "failed"
    assert "unexpected RuntimeError: exploded with ***" in o["reason"]
    assert "::warning::release-summary: unexpected RuntimeError" in seen.out
    assert TOKEN not in seen.out + seen.err + env.read_text()


def test_output_values_stay_on_one_line(mod, slack, env):
    slack.queue(REPLIES, {"ok": False, "error": "line one\nresult=posted"})
    o = run_main(mod, env)
    assert o["result"] == "skipped"
    assert len(env.read_text().splitlines()) == 3


def test_emit_writes_one_line_per_key(mod, env):
    mod.emit("reason", "first\nresult=posted")
    assert env.read_text() == "reason=first result=posted\n"


def test_runs_without_github_output(mod, env, monkeypatch):
    monkeypatch.delenv("GITHUB_OUTPUT")
    monkeypatch.setenv("SLACK_BOT_TOKEN", "")
    mod.main()


def test_unwritable_github_output_only_warns(mod, env, monkeypatch, tmp_path, capsys):
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path))
    monkeypatch.setenv("SLACK_BOT_TOKEN", "")
    mod.main()
    assert "could not write output result" in capsys.readouterr().out


def test_script_exits_zero_when_slack_is_unreachable(env):
    """Run it as the action does: a dead endpoint must not fail the job."""
    proc = subprocess.run(
        [sys.executable, str(SRC)], capture_output=True, text=True, timeout=60,
        env={**os.environ, "SLACK_API_URL": "http://127.0.0.1:9",
             "RELEASE_SUMMARY_RETRY_SLEEP": "0"})
    assert proc.returncode == 0
    o = outputs(env)
    assert o["result"] == "skipped"
    assert "could not read the banner thread" in o["reason"]
    assert "::warning::release-summary:" in proc.stdout
    assert TOKEN not in proc.stdout + proc.stderr + env.read_text()

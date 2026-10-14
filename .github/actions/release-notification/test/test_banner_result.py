"""banner-result.py: when the bot token banner counts as posted, and when the
webhook posts it instead. A scripted Slack Web API runs on a loopback port,
so the real urllib path is exercised with no network and no real token."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "banner-result.py"
TOKEN = "xoxb-test-secret-0123456789"
CHANNEL = "C0123ABCD"
REPO = "loft-sh/loft-enterprise"
VERSION = "v4.6.0-alpha.3"


def load():
    spec = importlib.util.spec_from_file_location("banner_result", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeSlack:
    """Answers conversations.history with the queued responses: a dict is a
    200 JSON body, an int is a bare HTTP status. Records every request."""

    def __init__(self):
        self.responses: list = []
        self.requests: list[dict] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                outer.requests.append({"path": parsed.path,
                                       "query": urllib.parse.parse_qs(parsed.query),
                                       "auth": self.headers.get("Authorization")})
                reply = outer.responses.pop(0) if outer.responses else 418
                status, body = (reply, {}) if isinstance(reply, int) else (200, reply)
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}/api"
        threading.Thread(target=self.server.serve_forever, args=(0.01,), daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def env(tmp_path, monkeypatch):
    out = tmp_path / "github_output"
    out.write_text("")
    for key, value in {"GITHUB_OUTPUT": str(out), "SLACK_BOT_TOKEN": TOKEN,
                       "CHANNEL_ID": CHANNEL, "REPOSITORY": REPO, "VERSION": VERSION,
                       "HAS_WEBHOOK": "true", "POST_OK": "", "POST_RESPONSE": "",
                       "POST_TS": "", "BANNER_CHECK_DELAY": "0",
                       "SLACK_API_URL": "http://127.0.0.1:9",
                       "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"}.items():
        monkeypatch.setenv(key, value)
    return out


@pytest.fixture
def slack(env, monkeypatch):
    fake = FakeSlack()
    monkeypatch.setenv("SLACK_API_URL", fake.url)
    yield fake
    fake.close()


def run(env) -> tuple[int, dict[str, str]]:
    code = load().main()
    out = dict(line.split("=", 1) for line in env.read_text().splitlines() if "=" in line)
    return code, out


def banner(ts: str, version=VERSION, repository=REPO) -> dict:
    return {"ts": ts, "text": "New release",
            "metadata": {"event_type": "release_banner",
                         "event_payload": {"repository": repository, "version": version}}}


def history(*messages) -> dict:
    return {"ok": True, "messages": list(messages)}


def test_ok_post_is_posted_without_reading_the_channel(slack, env, monkeypatch):
    monkeypatch.setenv("POST_OK", "true")
    monkeypatch.setenv("POST_TS", "1700000001.000100")
    code, out = run(env)
    assert code == 0
    assert out == {"posted": "true", "ts": "1700000001.000100",
                   "channel_id": CHANNEL, "fallback": "false", "webhook_retries": "0"}
    assert slack.requests == []


@pytest.mark.parametrize("error,remedy", [
    ("not_in_channel", "invite the bot"),
    ("invalid_auth", "valid bot token"),
    ("channel_not_found", "slack_channel_id"),
    ("missing_scope", "chat:write"),
    ("ratelimited", None),
    ("invalid_blocks", None),
])
def test_rejected_post_falls_back_without_reading_the_channel(slack, env, monkeypatch, capsys,
                                                             error, remedy):
    monkeypatch.setenv("POST_OK", "false")
    monkeypatch.setenv("POST_RESPONSE", json.dumps({"ok": False, "error": error}))
    code, out = run(env)
    assert code == 0
    assert out == {"posted": "false", "ts": "", "channel_id": "", "fallback": "true",
                   "webhook_retries": "0"}
    assert slack.requests == []
    text = capsys.readouterr().out
    assert f"::warning::Slack rejected the bot token banner ({error})" in text
    assert "Falling back to the webhook" in text
    if remedy:
        assert remedy in text


AMBIGUOUS = [
    json.dumps({"ok": False, "error": "internal_error"}),
    json.dumps({"ok": False, "error": "request_timeout"}),
    json.dumps({"code": "slack_webapi_http_error", "statusCode": 503}),
    json.dumps({}),  # a request error serializes to an empty object
    "",              # a rate limit after the last retry sets no response
    "not json",
]


@pytest.mark.parametrize("response", AMBIGUOUS)
def test_ambiguous_post_that_landed_is_posted_with_no_fallback(slack, env, monkeypatch, response):
    monkeypatch.setenv("POST_OK", "false")
    monkeypatch.setenv("POST_RESPONSE", response)
    slack.responses.append(history({"ts": "1700000002.000100", "text": "chatter"},
                                   banner("1700000001.000100")))
    code, out = run(env)
    assert code == 0
    assert out["posted"] == "true" and out["ts"] == "1700000001.000100"
    assert out["fallback"] == "false"
    (req,) = slack.requests
    assert req["path"] == "/api/conversations.history"
    assert req["query"]["channel"] == [CHANNEL]
    assert req["query"]["include_all_metadata"] == ["true"]
    assert "oldest" in req["query"]
    assert req["auth"] == f"Bearer {TOKEN}"


@pytest.mark.parametrize("other", [
    banner("1700000001.000100", version="v4.6.0-alpha.2"),
    banner("1700000001.000100", repository="loft-sh/vcluster-pro"),
    {"ts": "1700000001.000100", "metadata": {"event_type": "release_summary",
                                             "event_payload": {"repository": REPO,
                                                               "version": VERSION}}},
    {"ts": "1700000001.000100", "metadata": "junk"},
])
def test_ambiguous_post_not_in_the_channel_falls_back(slack, env, monkeypatch, capsys, other):
    monkeypatch.setenv("POST_RESPONSE", json.dumps({"ok": False, "error": "internal_error"}))
    slack.responses.append(history(other))
    code, out = run(env)
    assert code == 0
    assert out["posted"] == "false" and out["fallback"] == "true"
    assert "the banner is not in the channel" in capsys.readouterr().out


@pytest.mark.parametrize("reply,error", [
    ({"ok": False, "error": "missing_scope"}, "missing_scope"),
    (500, "http_500"),
    ({"unexpected": True}, "unknown_error"),
])
def test_unreadable_channel_falls_back_and_says_it_may_duplicate(slack, env, monkeypatch, capsys,
                                                                 reply, error):
    monkeypatch.setenv("POST_RESPONSE", json.dumps({"ok": False, "error": "fatal_error"}))
    slack.responses.append(reply)
    code, out = run(env)
    assert code == 0
    assert out["fallback"] == "true"
    text = capsys.readouterr().out
    assert f"({error}; the bot needs channels:history)" in text
    assert "may duplicate the banner" in text


def test_banner_on_a_later_page_is_found(slack, env, monkeypatch):
    """A busy channel can push the banner past the first page: absence is
    only proven once the read is exhausted."""
    monkeypatch.setenv("POST_RESPONSE", json.dumps({"ok": False, "error": "internal_error"}))
    first = history({"ts": "1700000003.000100", "text": "chatter"})
    first["response_metadata"] = {"next_cursor": "page2"}
    first["has_more"] = True
    slack.responses += [first, history(banner("1700000001.000100"))]
    code, out = run(env)
    assert (code, out["posted"], out["fallback"]) == (0, "true", "false")
    assert out["ts"] == "1700000001.000100"
    assert "cursor" not in slack.requests[0]["query"]
    assert slack.requests[1]["query"]["cursor"] == ["page2"]


@pytest.mark.parametrize("pages,needle", [
    # has_more without a cursor: the read stopped short
    ([{"ok": True, "messages": [], "has_more": True}], "history_incomplete"),
    # every page points at another one, past the page cap
    ([{"ok": True, "messages": [], "has_more": True,
       "response_metadata": {"next_cursor": f"c{i}"}} for i in range(5)], "more than 1000 messages"),
])
def test_an_unfinished_read_is_not_proof_of_absence(slack, env, monkeypatch, capsys, pages, needle):
    monkeypatch.setenv("POST_RESPONSE", json.dumps({"ok": False, "error": "internal_error"}))
    slack.responses += pages
    code, out = run(env)
    assert (code, out["fallback"]) == (0, "true")
    text = capsys.readouterr().out
    assert needle in text
    assert "may duplicate the banner" in text
    assert "is not in the channel" not in text


def test_unreachable_slack_falls_back(env, monkeypatch):
    monkeypatch.setenv("POST_RESPONSE", "")
    code, out = run(env)
    assert code == 0
    assert out["fallback"] == "true"


def test_no_webhook_to_fall_back_on_fails_the_step(slack, env, monkeypatch, capsys):
    monkeypatch.setenv("HAS_WEBHOOK", "false")
    monkeypatch.setenv("POST_RESPONSE", json.dumps({"ok": False, "error": "not_in_channel"}))
    code, out = run(env)
    assert code == 1
    assert out == {"posted": "false", "ts": "", "channel_id": "", "fallback": "false",
                   "webhook_retries": "0"}
    assert "::error::Slack rejected the bot token banner (not_in_channel)" in capsys.readouterr().out


def test_no_webhook_but_the_banner_landed_succeeds(slack, env, monkeypatch):
    monkeypatch.setenv("HAS_WEBHOOK", "false")
    slack.responses.append(history(banner("1700000001.000100")))
    code, out = run(env)
    assert code == 0
    assert out["posted"] == "true"


def test_token_never_reaches_output(slack, env, monkeypatch, capsys):
    monkeypatch.setenv("POST_RESPONSE", json.dumps({"ok": False, "error": "internal_error",
                                                    "detail": TOKEN}))
    slack.responses.append(history())
    run(env)
    assert TOKEN not in capsys.readouterr().out
    assert TOKEN not in env.read_text()


def test_unexpected_error_falls_back(env, monkeypatch, capsys):
    mod = load()

    def boom():
        raise RuntimeError("bug")

    mod.decide = boom
    assert mod.main() == 0
    assert "fallback=true" in env.read_text()
    assert "RuntimeError: bug" in capsys.readouterr().out


def test_script_runs_as_a_process(slack, env):
    proc = subprocess.run([sys.executable, str(SRC)], capture_output=True, text=True,
                          timeout=30, env={**__import__("os").environ, "POST_OK": "true",
                                           "POST_TS": "1700000001.000100"})
    assert proc.returncode == 0
    assert "posted=true" in env.read_text()

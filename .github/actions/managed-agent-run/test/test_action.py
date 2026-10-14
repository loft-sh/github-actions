import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ACTION = Path(__file__).parents[1] / "src" / "action.py"
NAME = "scheduled-routines-cve-remediation"


class FakeAnthropic:
    def __init__(self, pages=None, run_result=None, error_status=None):
        self.calls = []
        self.pages = pages if pages is not None else [[{"id": "dep_1", "name": NAME}]]
        self.run_result = run_result if run_result is not None else {
            "id": "run_1", "session_id": "sesn_1", "type": "deployment_run"}
        parent = self

        class Handler(BaseHTTPRequestHandler):
            def _reply(self, payload):
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _record(self):
                url = urlparse(self.path)
                parent.calls.append({
                    "method": self.command,
                    "path": url.path,
                    "query": {k: v[0] for k, v in parse_qs(url.query).items()},
                    "headers": {k.lower(): v for k, v in self.headers.items()},
                })
                if error_status is not None:
                    self.send_response(error_status)
                    self.end_headers()
                    return None
                return url

            def do_GET(self):
                url = self._record()
                if url is None:
                    return
                page = int(parse_qs(url.query).get("page", ["0"])[0])
                last = page + 1 >= len(parent.pages)
                self._reply({"data": parent.pages[page], "next_page": None if last else str(page + 1)})

            def do_POST(self):
                if self._record() is None:
                    return
                self._reply(parent.run_result)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.server.shutdown()


def run_action(tmp_path, server, **inputs):
    env = {
        "PATH": os.environ["PATH"],
        "ANTHROPIC_API_URL": server.url,
        "GITHUB_OUTPUT": str(tmp_path / "output"),
        "GITHUB_STEP_SUMMARY": str(tmp_path / "summary"),
        "INPUT_ANTHROPIC_API_KEY": "sk-test",
        "INPUT_DEPLOYMENT_NAME": NAME,
        "INPUT_ENABLED": "true",
        "INPUT_DRY_RUN": "false",
    }
    env.update({f"INPUT_{k.upper()}": v for k, v in inputs.items()})
    result = subprocess.run(["python3", str(ACTION)], env=env, capture_output=True, text=True)
    output = (tmp_path / "output").read_text() if (tmp_path / "output").exists() else ""
    return result, output


def test_starts_the_run_and_sets_outputs(tmp_path):
    with FakeAnthropic() as server:
        result, output = run_action(tmp_path, server)
    assert result.returncode == 0
    assert [(c["method"], c["path"]) for c in server.calls] == [
        ("GET", "/v1/deployments"), ("POST", "/v1/deployments/dep_1/run")]
    for call in server.calls:
        assert call["query"]["beta"] == "true"
        assert call["headers"]["x-api-key"] == "sk-test"
        assert call["headers"]["anthropic-beta"] == "managed-agents-2026-04-01"
    assert "run-id=run_1" in output
    assert "session-id=sesn_1" in output
    assert "sesn_1" in (tmp_path / "summary").read_text()


def test_follows_pagination(tmp_path):
    with FakeAnthropic(pages=[[{"id": "dep_0", "name": "other"}], [{"id": "dep_9", "name": NAME}]]) as server:
        result, _ = run_action(tmp_path, server)
    assert result.returncode == 0
    assert [c["query"].get("page") for c in server.calls if c["method"] == "GET"] == [None, "1"]
    assert server.calls[-1]["path"] == "/v1/deployments/dep_9/run"


def test_kill_switch_makes_no_requests(tmp_path):
    with FakeAnthropic() as server:
        result, output = run_action(tmp_path, server, enabled="false")
    assert result.returncode == 0
    assert server.calls == []
    assert output == ""
    assert "disabled" in result.stdout


def test_missing_key_makes_no_requests(tmp_path):
    with FakeAnthropic() as server:
        result, _ = run_action(tmp_path, server, anthropic_api_key="")
    assert result.returncode == 0
    assert server.calls == []
    assert "anthropic-api-key is empty" in result.stdout


def test_dry_run_resolves_without_running(tmp_path):
    with FakeAnthropic() as server:
        result, output = run_action(tmp_path, server, dry_run="true")
    assert result.returncode == 0
    assert [c["method"] for c in server.calls] == ["GET"]
    assert output == ""
    assert "would run" in result.stdout


def test_unknown_or_ambiguous_name_warns_without_running(tmp_path):
    for pages in ([[{"id": "dep_0", "name": "other"}]],
                  [[{"id": "dep_1", "name": NAME}, {"id": "dep_2", "name": NAME}]]):
        with FakeAnthropic(pages=pages) as server:
            result, output = run_action(tmp_path, server)
        assert result.returncode == 0
        assert all(c["method"] == "GET" for c in server.calls)
        assert "::warning::" in result.stdout
        assert "session-id" not in output


def test_api_failure_never_fails_the_job(tmp_path):
    with FakeAnthropic(error_status=500) as server:
        result, output = run_action(tmp_path, server)
    assert result.returncode == 0
    assert "::warning::" in result.stdout
    assert "the calling job is unaffected" in result.stdout
    assert output == ""


def test_run_without_session_warns(tmp_path):
    with FakeAnthropic(run_result={"id": "run_1", "error": {"type": "agent_archived"}}) as server:
        result, output = run_action(tmp_path, server)
    assert result.returncode == 0
    assert "created no session (error: agent_archived)" in result.stdout
    assert output == ""


def test_unrecognised_enabled_disables(tmp_path):
    with FakeAnthropic() as server:
        result, output = run_action(tmp_path, server, enabled="maybe")
    assert result.returncode == 0
    assert "unrecognised enabled='maybe'; using the safe default 'false'" in result.stdout
    assert server.calls == []
    assert output == ""


def test_unrecognised_dry_run_stays_dry(tmp_path):
    with FakeAnthropic() as server:
        result, _ = run_action(tmp_path, server, dry_run="maybe")
    assert result.returncode == 0
    assert "unrecognised dry-run='maybe'" in result.stdout
    assert [c["method"] for c in server.calls] == ["GET"]

"""Fail-soft matrix for run.py's session mode, driven against a stubbed
anthropic SDK — no network, no tokens spent.

Every fail path must end the process with exit code 0 (fail_soft raises
SystemExit(0)), an empty `result` block and `conclusion=failed` in
$GITHUB_OUTPUT, and — once the session or environment exists — a delete
call for each. That is the action's advisory contract and DEVOPS-1352
acceptance criteria 3, 4, and 6-9.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import types
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "run.py"


class FakeAPIError(Exception):
    body = ""


def _obj(**kw):
    return types.SimpleNamespace(**kw)


class FakeClient:
    """Just enough of anthropic.Anthropic for run_session: agents.list,
    environments.create/delete, sessions create/retrieve/delete and
    events send/list. Tests steer it via the ctor knobs and read back
    the `deleted` record."""

    def __init__(self, *, agents=("sre-memory-curator",),
                 statuses=("idle",), stop_reason="end_turn",
                 final_text='{"ok": true}', create_raises=None,
                 idle_event_delay=0, stop_is_str=False):
        self._statuses = list(statuses)
        self._stop = stop_reason
        self._final = final_text
        self._create_raises = create_raises
        # status_idle event lags the status flip in the live API; this
        # many lookups return empty before the event becomes visible
        self._idle_delay = idle_event_delay
        self._stop_is_str = stop_is_str
        self.deleted = {"sessions": [], "environments": []}
        self.sent = []

        client = self

        class Events:
            def send(self, sid, events):
                client.sent.append(events)

            def list(self, sid, types=None, order=None, limit=None):
                if types == ["session.status_idle"]:
                    if client._idle_delay > 0:
                        client._idle_delay -= 1
                        return iter([])
                    if client._stop is None:
                        return iter([])
                    stop = client._stop if client._stop_is_str else _obj(type=client._stop)
                    return iter([_obj(stop_reason=stop)])
                if types == ["agent.message"]:
                    if client._final is None:
                        return iter([])
                    return iter([_obj(content=[_obj(type="text", text=client._final)])])
                return iter([])

        class Sessions:
            events = Events()

            def create(self, **kw):
                if client._create_raises:
                    raise client._create_raises
                return _obj(id="sess_test")

            def retrieve(self, sid):
                status = client._statuses.pop(0) if len(client._statuses) > 1 else client._statuses[0]
                return _obj(status=status)

            def delete(self, sid):
                client.deleted["sessions"].append(sid)

        class Environments:
            def create(self, **kw):
                return _obj(id="env_test")

            def delete(self, eid):
                client.deleted["environments"].append(eid)

        class Agents:
            def list(self):
                return iter([_obj(name=n, id=f"agent_{n}") for n in agents])

        self.beta = _obj(sessions=Sessions(), environments=Environments(), agents=Agents())


@pytest.fixture()
def run_mod(monkeypatch, tmp_path):
    """Import run.py fresh with a stubbed anthropic module and a
    per-test GITHUB_OUTPUT; poll delay zeroed so timeout tests spin
    in real milliseconds."""
    fake = types.ModuleType("anthropic")
    fake.APIError = FakeAPIError
    fake.Anthropic = None  # each test injects its FakeClient factory
    monkeypatch.setitem(sys.modules, "anthropic", fake)

    out = tmp_path / "github_output"
    out.touch()
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))

    spec = importlib.util.spec_from_file_location("ai_step_run", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    monkeypatch.setattr(mod, "POLL_INTERVAL_S", 0)
    monkeypatch.setattr(mod, "STOP_REASON_GRACE_S", 0.3)
    mod._out_path = out
    mod._fake = fake
    return mod


def _wire(mod, client):
    mod._fake.Anthropic = lambda **kw: client
    return client


def _output(mod):
    return mod._out_path.read_text()


def _assert_failed(mod):
    text = _output(mod)
    assert "conclusion=failed" in text
    assert "result<<AISTEP_EOF\n\nAISTEP_EOF" in text


def _run(mod, client, timeout_s=60):
    _wire(mod, client)
    return mod.run_session("sre-memory-curator", "hi", "sk-key", "", timeout_s)


def test_agent_not_found_fails_soft(run_mod):
    client = FakeClient(agents=("someone-else",))
    with pytest.raises(SystemExit) as e:
        _run(run_mod, client)
    assert e.value.code == 0
    _assert_failed(run_mod)
    # nothing was created, so nothing to delete
    assert client.deleted == {"sessions": [], "environments": []}


def test_timeout_fails_soft_and_deletes(run_mod):
    client = FakeClient(statuses=("running",))
    with pytest.raises(SystemExit) as e:
        _run(run_mod, client, timeout_s=0.2)
    assert e.value.code == 0
    _assert_failed(run_mod)
    assert client.deleted["sessions"] == ["sess_test"]
    assert client.deleted["environments"] == ["env_test"]


def test_terminated_fails_soft_and_deletes(run_mod):
    client = FakeClient(statuses=("running", "terminated"))
    with pytest.raises(SystemExit) as e:
        _run(run_mod, client)
    assert e.value.code == 0
    _assert_failed(run_mod)
    assert client.deleted["sessions"] == ["sess_test"]


def test_non_end_turn_stop_fails_soft(run_mod):
    client = FakeClient(stop_reason="retries_exhausted")
    with pytest.raises(SystemExit) as e:
        _run(run_mod, client)
    assert e.value.code == 0
    _assert_failed(run_mod)
    assert client.deleted["sessions"] == ["sess_test"]


def test_late_status_idle_event_is_awaited(run_mod):
    # the live race (ai-agents run 32252874325): status flips to idle
    # before the status_idle event is listable; the grace loop must
    # absorb the lag instead of failing on the first empty read
    client = FakeClient(idle_event_delay=2)
    text = _run(run_mod, client)
    assert text == '{"ok": true}'
    assert client.deleted["sessions"] == ["sess_test"]


def test_status_idle_event_never_appears_fails_soft(run_mod):
    client = FakeClient(stop_reason=None)
    with pytest.raises(SystemExit) as e:
        _run(run_mod, client)
    assert e.value.code == 0
    _assert_failed(run_mod)
    assert client.deleted["sessions"] == ["sess_test"]


def test_string_stop_reason_is_accepted(run_mod):
    client = FakeClient(stop_is_str=True)
    text = _run(run_mod, client)
    assert text == '{"ok": true}'


def test_idle_without_message_fails_soft(run_mod):
    client = FakeClient(final_text=None)
    with pytest.raises(SystemExit) as e:
        _run(run_mod, client)
    assert e.value.code == 0
    _assert_failed(run_mod)


def test_unexpected_exception_fails_soft_and_deletes_env(run_mod):
    # blocker fix: a non-APIError inside the session sequence must not
    # escape as a traceback / non-zero exit
    client = FakeClient(create_raises=RuntimeError("kwarg rejected"))
    with pytest.raises(SystemExit) as e:
        _run(run_mod, client)
    assert e.value.code == 0
    _assert_failed(run_mod)
    assert client.deleted["environments"] == ["env_test"]


def test_session_key_is_masked_in_logs(run_mod, capsys):
    # public-repo posture: the runner must scrub the key from every log
    # line even when the caller did not source it from secrets.*
    client = FakeClient()
    _run(run_mod, client)
    assert "::add-mask::sk-key" in capsys.readouterr().out


def test_no_key_emits_no_mask_line(run_mod, capsys):
    client = FakeClient()
    _wire(run_mod, client)
    run_mod.run_session("sre-memory-curator", "hi", "", "", 60)
    assert "::add-mask::" not in capsys.readouterr().out


def test_no_key_builds_client_for_sdk_credential_chain(run_mod):
    # federation fallback: with no session key the client must be built
    # WITHOUT api_key so the SDK's credential chain (workload identity
    # federation env vars) can resolve the credential
    captured = {}
    client = FakeClient(statuses=("running", "idle"))

    def factory(**kw):
        captured.update(kw)
        return client

    run_mod._fake.Anthropic = factory
    text = run_mod.run_session("sre-memory-curator", "hi", "", "", 60)
    assert text == '{"ok": true}'
    assert "api_key" not in captured
    assert client.deleted["sessions"] == ["sess_test"]


def test_happy_path_returns_text_and_deletes(run_mod):
    client = FakeClient(statuses=("running", "idle"), final_text='{"ok": true}')
    text = _run(run_mod, client)
    assert text == '{"ok": true}'
    assert client.deleted["sessions"] == ["sess_test"]
    assert client.deleted["environments"] == ["env_test"]
    assert client.sent, "user.message was never sent"


def test_strip_fence_unwraps_and_preserves(run_mod):
    # observed live: agents fence their JSON since sessions have no
    # provider-side structured-output binding
    fenced = '```json\n{"ok": true}\n```'
    assert run_mod.strip_fence(fenced) == '{"ok": true}'
    assert run_mod.strip_fence('{"ok": true}') == '{"ok": true}'
    assert run_mod.strip_fence("just prose") == "just prose"
    unclosed = '```json\n{"ok": true}'
    assert run_mod.strip_fence(unclosed) == unclosed


def test_validate_output_rejects_schema_violation(run_mod):
    pytest.importorskip("jsonschema")
    with pytest.raises(SystemExit) as e:
        run_mod.validate_output({"ok": "yes"},
                                {"type": "object",
                                 "properties": {"ok": {"type": "boolean"}}},
                                '{"ok": "yes"}')
    assert e.value.code == 0
    _assert_failed(run_mod)


def test_validate_output_accepts_conforming(run_mod):
    pytest.importorskip("jsonschema")
    run_mod.validate_output({"ok": True},
                            {"type": "object",
                             "properties": {"ok": {"type": "boolean"}}},
                            '{"ok": true}')
    assert "conclusion=failed" not in _output(run_mod)

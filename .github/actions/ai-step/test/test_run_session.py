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
import re
import sys
import types
from datetime import datetime, timedelta, timezone
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
                 statuses=("running", "idle"), stop_reason="end_turn",
                 final_text='{"ok": true}', create_raises=None,
                 idle_event_delay=0, stop_is_str=False,
                 fresh_idle_event=True, delete_raises=None,
                 retrieve_raises=None, interrupt_status="idle", send_unprocessed=False):
        self._statuses = list(statuses)
        self._stop = stop_reason
        self._final = final_text
        self._create_raises = create_raises
        # status_idle event lags the status flip in the live API; this
        # many lookups return empty before the event becomes visible
        self._idle_delay = idle_event_delay
        self._stop_is_str = stop_is_str
        self._fresh_idle_event = fresh_idle_event
        self._delete_raises = delete_raises
        self._retrieve_raises = retrieve_raises
        self._interrupt_status = interrupt_status
        self._send_unprocessed = send_unprocessed
        self.deleted = {"sessions": [], "environments": []}
        self.sent = []
        self.cleanup_order = []

        client = self

        class Events:
            def send(self, sid, events):
                client.sent.append(events)
                if events[0].get("type") == "user.interrupt":
                    client.cleanup_order.append("interrupt")
                    client._statuses = [client._interrupt_status]
                else:
                    client._sent_at = datetime.now(timezone.utc)
                    return _obj(data=[_obj(id="msg_test", processed_at=(
                        None if client._send_unprocessed else client._sent_at))])

            def list(self, sid, types=None, order=None, limit=None):
                if types == ["user.message"]:
                    return iter([_obj(id="msg_test", processed_at=client._sent_at)])
                if types == ["session.status_idle"]:
                    if client._idle_delay > 0:
                        client._idle_delay -= 1
                        return iter([])
                    if client._stop is None:
                        return iter([])
                    stop = client._stop if client._stop_is_str else _obj(type=client._stop)
                    created_at = (datetime.now(timezone.utc) + timedelta(seconds=1)
                                  if client._fresh_idle_event else
                                  datetime.now(timezone.utc) - timedelta(seconds=5))
                    return iter([_obj(stop_reason=stop, created_at=created_at)])
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
                if client._retrieve_raises:
                    raise client._retrieve_raises
                status = client._statuses.pop(0) if len(client._statuses) > 1 else client._statuses[0]
                return _obj(status=status)

            def delete(self, sid):
                client.cleanup_order.append("delete-session")
                if client._delete_raises:
                    err, client._delete_raises = client._delete_raises, None
                    raise err
                client.deleted["sessions"].append(sid)

        class Environments:
            def create(self, **kw):
                return _obj(id="env_test")

            def delete(self, eid):
                client.cleanup_order.append("delete-environment")
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
    monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))

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


def test_app_rotation_precedes_session_and_keeps_wif(run_mod, monkeypatch):
    calls = []
    client = FakeClient()
    original_create = client.beta.sessions.create
    client.beta.sessions.create = lambda **kwargs: (calls.append("session") or original_create(**kwargs))
    client_factory_args = []
    run_mod._fake.Anthropic = lambda **kwargs: (client_factory_args.append(kwargs) or client)

    class FakeCredential:
        def __init__(self, client, vault, **config):
            assert vault == "vlt"
        def renew(self, force=False):
            calls.append("initial" if force else "poll")

    monkeypatch.setitem(sys.modules, "github_app", _obj(AppError=RuntimeError, GitHubCredential=FakeCredential))
    result = run_mod.run_session("sre-memory-curator", "hi", "", "vlt", 60, {"key": "secret"})
    assert result == '{"ok": true}'
    assert calls[0:2] == ["initial", "session"]
    assert "poll" in calls
    assert "api_key" not in client_factory_args[0]
    assert client.deleted == {"sessions": ["sess_test"], "environments": ["env_test"]}


def test_renewal_failure_interrupts_and_cleans_up(run_mod, monkeypatch, capsys):
    client = _wire(run_mod, FakeClient(statuses=("running",)))

    class FakeCredential:
        def __init__(self, *args, **kwargs):
            pass
        def renew(self, force=False):
            if not force:
                raise RuntimeError("secret-token")

    monkeypatch.setitem(sys.modules, "github_app", _obj(AppError=RuntimeError, GitHubCredential=FakeCredential))
    with pytest.raises(SystemExit):
        run_mod.run_session("sre-memory-curator", "hi", "", "vlt", 60, {"key": "secret"})
    assert client.cleanup_order == ["interrupt", "delete-session", "delete-environment"]
    assert "secret-token" not in capsys.readouterr().out


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
    assert "interrupt" in client.cleanup_order


def test_delayed_startup_idle_does_not_finish_session(run_mod):
    # An initial idle is startup lag. Completion is accepted once running
    # has been observed and the session returns to idle.
    client = FakeClient(statuses=("idle", "running", "idle"),
                        idle_event_delay=1, fresh_idle_event=True)
    assert _run(run_mod, client) == '{"ok": true}'
    assert client.deleted["sessions"] == ["sess_test"]


def test_stale_idle_event_cannot_finish_session(run_mod):
    client = FakeClient(statuses=("idle",), fresh_idle_event=False)
    with pytest.raises(SystemExit) as e:
        _run(run_mod, client, timeout_s=0.01)
    assert e.value.code == 0
    _assert_failed(run_mod)
    # Idle may mean the submitted turn has not started yet. Do not delete
    # either resource while it could still start using the environment.
    assert client.deleted == {"sessions": [], "environments": []}


def test_failure_before_send_confirmation_keeps_idle_session_environment(run_mod):
    client = FakeClient(statuses=("idle",))
    def fail_send(sid, events):
        raise RuntimeError("send result unavailable")
    client.beta.sessions.events.send = fail_send
    with pytest.raises(SystemExit):
        _run(run_mod, client)
    assert client.deleted == {"sessions": [], "environments": []}


def test_fast_completion_uses_fresh_idle_event_without_running_poll(run_mod):
    client = FakeClient(statuses=("idle",), fresh_idle_event=True)
    assert _run(run_mod, client) == '{"ok": true}'


def test_idle_event_without_message_timestamp_is_not_fresh(run_mod):
    event = _obj(processed_at=datetime.now(timezone.utc))
    assert not run_mod.event_is_newer_than(event, None)


def test_unprocessed_send_fetches_message_timestamp(run_mod):
    client = FakeClient(statuses=("idle",), send_unprocessed=True)
    assert _run(run_mod, client) == '{"ok": true}'


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


def test_refused_session_delete_keeps_environment(run_mod):
    client = FakeClient(statuses=("idle",), delete_raises=RuntimeError("delete refused"))
    assert _run(run_mod, client) == '{"ok": true}'
    assert client.deleted["sessions"] == []
    assert client.deleted["environments"] == []
    assert "delete-environment" not in client.cleanup_order


def test_unknown_status_after_refused_delete_keeps_environment(run_mod):
    client = FakeClient(statuses=("running",), delete_raises=RuntimeError("refused"),
                        retrieve_raises=RuntimeError("status unavailable"))
    with pytest.raises(SystemExit):
        _run(run_mod, client, timeout_s=0.01)
    assert client.deleted["environments"] == []


def test_unrecognized_status_after_interrupt_keeps_environment(run_mod):
    client = FakeClient(statuses=("running",), delete_raises=RuntimeError("refused"),
                        interrupt_status="starting")
    with pytest.raises(SystemExit):
        _run(run_mod, client, timeout_s=0.01)
    assert client.deleted["environments"] == []


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


# --- log-output --------------------------------------------------------------

SECRET = "abcdef.0123456789abcdef"
BOOL_SCHEMA = {"type": "object", "properties": {"ok": {"type": "boolean"}}}


def test_schema_error_quotes_the_value_by_default(run_mod, monkeypatch, capsys):
    pytest.importorskip("jsonschema")
    monkeypatch.delenv("INPUT_LOG_OUTPUT", raising=False)
    with pytest.raises(SystemExit):
        run_mod.validate_output({"ok": SECRET}, BOOL_SCHEMA, f'{{"ok": "{SECRET}"}}')
    assert SECRET in capsys.readouterr().out
    assert SECRET in _output(run_mod)


def test_log_output_false_keeps_the_value_out_of_a_schema_error(run_mod, monkeypatch, capsys):
    pytest.importorskip("jsonschema")
    monkeypatch.setenv("INPUT_LOG_OUTPUT", "false")
    with pytest.raises(SystemExit) as e:
        run_mod.validate_output({"ok": SECRET}, BOOL_SCHEMA, f'{{"ok": "{SECRET}"}}')
    assert e.value.code == 0
    _assert_failed(run_mod)
    out = capsys.readouterr().out
    assert SECRET not in out
    assert SECRET not in _output(run_mod)
    assert "fails 'type' at properties/ok/type" in _output(run_mod)


def _main_session(mod, monkeypatch, client, **extra):
    env = {"INPUT_PROVIDER": "anthropic", "INPUT_MODE": "session",
           "INPUT_AGENT": "sre-memory-curator", "INPUT_PROMPT": "hi",
           "INPUT_OUTPUT_SCHEMA": '{"type": "object"}',
           "INPUT_ANTHROPIC_SESSION_KEY": "sk-key", **extra}
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    _wire(mod, client)
    mod.main()


def test_session_answer_is_printed_by_default(run_mod, monkeypatch, capsys):
    pytest.importorskip("jsonschema")
    monkeypatch.delenv("INPUT_LOG_OUTPUT", raising=False)
    _main_session(run_mod, monkeypatch, FakeClient(final_text=f'{{"note": "{SECRET}"}}'))
    assert SECRET in capsys.readouterr().out


def test_log_output_false_keeps_the_session_answer_out_of_the_log(run_mod, monkeypatch, capsys):
    pytest.importorskip("jsonschema")
    _main_session(run_mod, monkeypatch, FakeClient(final_text=f'{{"note": "{SECRET}"}}'),
                  INPUT_LOG_OUTPUT="false")
    out = capsys.readouterr().out
    assert SECRET not in out
    assert "→ success" in out
    assert SECRET in _output(run_mod)


def test_session_result_file_holds_the_answer(run_mod, monkeypatch, tmp_path):
    pytest.importorskip("jsonschema")
    answer = f'{{"note": "{SECRET}"}}'
    _main_session(run_mod, monkeypatch, FakeClient(final_text=answer), INPUT_LOG_OUTPUT="false")
    path = re.findall(r"^result-file=(.*)$", _output(run_mod), re.MULTILINE)
    assert len(path) == 1
    assert Path(path[0]).parent == tmp_path
    assert Path(path[0]).read_text() == answer

"""Single-call mode of run.py against stubbed anthropic and openai SDKs:
the max-tokens input, truncation detection, and the `reason` output that
fail_soft emits. No network, no tokens spent.

Every fail path must end the process with exit code 0 (fail_soft raises
SystemExit(0)), an empty `result` block, `conclusion=failed` and a one-line
`reason` in $GITHUB_OUTPUT. That is the action's advisory contract.
"""
from __future__ import annotations

import importlib.util
import re
import sys
import types
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "run.py"
ACTION = Path(__file__).resolve().parent.parent / "action.yml"


class FakeAPIError(Exception):
    body = ""


def _obj(**kw):
    return types.SimpleNamespace(**kw)


class FakeAnthropic:
    """Records messages.create kwargs and returns a canned response."""

    def __init__(self, *, text='{"ok": true}', stop_reason="end_turn", content=None):
        self.calls = []
        blocks = [_obj(text=text)] if content is None else content
        self._resp = _obj(content=blocks, stop_reason=stop_reason,
                          model_dump=lambda: {"content": [], "stop_reason": stop_reason})
        client = self

        class Messages:
            def create(self, **kw):
                client.calls.append(kw)
                return client._resp

        self.messages = Messages()


class FakeOpenAI:
    """Records chat.completions.create kwargs and returns a canned choice."""

    def __init__(self, *, text='{"ok": true}', finish_reason="stop"):
        self.calls = []
        choice = _obj(message=_obj(content=text), finish_reason=finish_reason)
        self._resp = _obj(choices=[choice], model_dump=lambda: {})
        client = self

        class Completions:
            def create(self, **kw):
                client.calls.append(kw)
                return client._resp

        self.chat = _obj(completions=Completions())


@pytest.fixture()
def run_mod(monkeypatch, tmp_path):
    """Import run.py fresh with stubbed provider SDKs, a per-test
    GITHUB_OUTPUT, and a clean single-mode environment."""
    for name in ("INPUT_MAX_TOKENS", "INPUT_INPUT", "INPUT_INPUT_FILE", "INPUT_MODE"):
        monkeypatch.delenv(name, raising=False)

    anthropic = types.ModuleType("anthropic")
    anthropic.APIError = FakeAPIError
    anthropic.Anthropic = None  # each test injects its client
    openai = types.ModuleType("openai")
    openai.APIError = FakeAPIError
    openai.OpenAI = None
    monkeypatch.setitem(sys.modules, "anthropic", anthropic)
    monkeypatch.setitem(sys.modules, "openai", openai)

    out = tmp_path / "github_output"
    out.touch()
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))

    spec = importlib.util.spec_from_file_location("ai_step_run_single", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod._out_path = out
    mod._anthropic = anthropic
    mod._openai = openai
    return mod


def _output(mod):
    return mod._out_path.read_text()


def _kv(mod, key):
    """Last `key=value` line in $GITHUB_OUTPUT, or None."""
    vals = re.findall(rf"^{key}=(.*)$", _output(mod), re.MULTILINE)
    return vals[-1] if vals else None


def _assert_failed(mod, reason_part):
    text = _output(mod)
    assert "conclusion=failed" in text
    assert "result<<AISTEP_EOF\n\nAISTEP_EOF" in text
    assert reason_part in (_kv(mod, "reason") or ""), text


def _env(monkeypatch, provider="anthropic", **extra):
    monkeypatch.setenv("INPUT_PROVIDER", provider)
    monkeypatch.setenv("INPUT_MODEL", "test-model")
    monkeypatch.setenv("INPUT_PROMPT", "summarize")
    monkeypatch.setenv("INPUT_OUTPUT_SCHEMA", '{"type": "object"}')
    monkeypatch.setenv("INPUT_ANTHROPIC_API_KEY", "sk-ant")
    monkeypatch.setenv("INPUT_OPENAI_API_KEY", "sk-oai")
    for k, v in extra.items():
        monkeypatch.setenv(k, v)


def _main_anthropic(mod, monkeypatch, client, **extra):
    _env(monkeypatch, "anthropic", **extra)
    mod._anthropic.Anthropic = lambda **kw: client
    mod.main()


def _main_openai(mod, monkeypatch, client, **extra):
    _env(monkeypatch, "openai", **extra)
    mod._openai.OpenAI = lambda **kw: client
    mod.main()


# --- max-tokens reaches the API ----------------------------------------------


def test_default_max_tokens_is_4096(run_mod, monkeypatch):
    # existing callers pass no max-tokens and must see no change
    client = FakeAnthropic()
    _main_anthropic(run_mod, monkeypatch, client)
    assert client.calls[0]["max_tokens"] == 4096
    assert _kv(run_mod, "conclusion") == "success"


def test_empty_max_tokens_uses_default(run_mod, monkeypatch):
    # a caller passing `max-tokens: ''` reaches run.py as an empty env var
    client = FakeAnthropic()
    _main_anthropic(run_mod, monkeypatch, client, INPUT_MAX_TOKENS="")
    assert client.calls[0]["max_tokens"] == 4096


def test_max_tokens_input_is_used_for_the_call(run_mod, monkeypatch):
    client = FakeAnthropic()
    _main_anthropic(run_mod, monkeypatch, client, INPUT_MAX_TOKENS="16000")
    assert client.calls[0]["max_tokens"] == 16000
    assert _kv(run_mod, "conclusion") == "success"


def test_sdk_nonstreaming_bound_is_accepted(run_mod, monkeypatch):
    # 21333 is the largest max_tokens the SDK allows without streaming
    # (3600 s * max_tokens / 128000 <= 600)
    client = FakeAnthropic()
    _main_anthropic(run_mod, monkeypatch, client, INPUT_MAX_TOKENS="21333")
    assert client.calls[0]["max_tokens"] == 21333
    assert run_mod.ANTHROPIC_MAX_TOKENS_CAP == 21333


def test_above_sdk_bound_fails_soft_before_calling_the_api(run_mod, monkeypatch):
    client = FakeAnthropic()
    with pytest.raises(SystemExit) as e:
        _main_anthropic(run_mod, monkeypatch, client, INPUT_MAX_TOKENS="21334")
    assert e.value.code == 0
    _assert_failed(run_mod, "max-tokens 21334 is above 21333")
    assert client.calls == []


@pytest.mark.parametrize("bad", ["abc", "0", "-3", "1.5", "1_000", " 4096", "٣"])
def test_invalid_max_tokens_fails_soft_before_calling_the_api(run_mod, monkeypatch, bad):
    client = FakeAnthropic()
    with pytest.raises(SystemExit) as e:
        _main_anthropic(run_mod, monkeypatch, client, INPUT_MAX_TOKENS=bad)
    assert e.value.code == 0
    _assert_failed(run_mod, "max-tokens must be a positive integer")
    assert client.calls == []


# --- truncation --------------------------------------------------------------


def test_anthropic_truncation_fails_soft_with_a_clear_reason(run_mod, monkeypatch, capsys):
    client = FakeAnthropic(text='{"prs": [{"n": 1}, {"n"', stop_reason="max_tokens")
    with pytest.raises(SystemExit) as e:
        _main_anthropic(run_mod, monkeypatch, client, INPUT_MAX_TOKENS="8192")
    assert e.value.code == 0
    _assert_failed(run_mod, "response truncated at max-tokens 8192; raise max-tokens")
    # the partial text is kept in the log for diagnosis, not on `result`
    assert '{"prs": [{"n": 1}, {"n"' in capsys.readouterr().out


def test_truncation_is_reported_not_a_json_parse_failure(run_mod, monkeypatch):
    # before the stop_reason check, cut-off JSON surfaced as
    # "provider returned non-JSON content"
    client = FakeAnthropic(text='{"prs": [', stop_reason="max_tokens")
    with pytest.raises(SystemExit):
        _main_anthropic(run_mod, monkeypatch, client)
    assert "non-JSON" not in (_kv(run_mod, "reason") or "")
    assert "truncated" in _kv(run_mod, "reason")


def test_truncation_with_no_content_blocks_still_fails_soft(run_mod, monkeypatch):
    client = FakeAnthropic(content=[], stop_reason="max_tokens")
    with pytest.raises(SystemExit) as e:
        _main_anthropic(run_mod, monkeypatch, client)
    assert e.value.code == 0
    _assert_failed(run_mod, "response truncated at max-tokens 4096")


def test_complete_response_is_not_flagged(run_mod, monkeypatch):
    client = FakeAnthropic(stop_reason="end_turn")
    _main_anthropic(run_mod, monkeypatch, client)
    assert _kv(run_mod, "conclusion") == "success"
    assert _kv(run_mod, "reason") is None


def test_openai_length_finish_reason_fails_soft(run_mod, monkeypatch):
    client = FakeOpenAI(text='{"prs": [', finish_reason="length")
    with pytest.raises(SystemExit) as e:
        _main_openai(run_mod, monkeypatch, client)
    assert e.value.code == 0
    _assert_failed(run_mod, "finish_reason=length")


def test_openai_complete_response_is_not_flagged(run_mod, monkeypatch):
    client = FakeOpenAI(finish_reason="stop")
    _main_openai(run_mod, monkeypatch, client)
    assert _kv(run_mod, "conclusion") == "success"


def test_openai_call_is_unchanged_by_max_tokens(run_mod, monkeypatch):
    # openai sets no token limit today; max-tokens (default 4096) must not
    # start capping it, and the SDK's non-streaming bound is anthropic-only
    client = FakeOpenAI()
    _main_openai(run_mod, monkeypatch, client, INPUT_MAX_TOKENS="50000")
    kw = client.calls[0]
    assert not {"max_tokens", "max_completion_tokens", "max_output_tokens"} & kw.keys()
    assert _kv(run_mod, "conclusion") == "success"


# --- reason output -----------------------------------------------------------


def test_fail_soft_emits_the_reason(run_mod):
    with pytest.raises(SystemExit) as e:
        run_mod.fail_soft("provider is down")
    assert e.value.code == 0
    assert _kv(run_mod, "reason") == "provider is down"
    assert _kv(run_mod, "conclusion") == "failed"


def test_reason_is_one_line_and_cannot_inject_outputs(run_mod):
    # exception text can span lines; a newline in a `key=value` line would
    # let it set another output such as conclusion=success
    with pytest.raises(SystemExit):
        run_mod.fail_soft("boom\nconclusion=success\r\nresult=forged")
    text = _output(run_mod)
    assert _kv(run_mod, "reason") == "boom conclusion=success result=forged"
    assert re.findall(r"^conclusion=(.*)$", text, re.MULTILINE) == ["failed"]
    assert not re.search(r"^result=", text, re.MULTILINE)


def test_long_reason_is_truncated(run_mod):
    with pytest.raises(SystemExit):
        run_mod.fail_soft("x" * 2000)
    reason = _kv(run_mod, "reason")
    assert len(reason) == run_mod.REASON_MAX_LEN
    assert reason.endswith("...")


def test_success_emits_no_reason(run_mod, monkeypatch):
    _main_anthropic(run_mod, monkeypatch, FakeAnthropic())
    assert _kv(run_mod, "reason") is None


# --- action.yml wiring -------------------------------------------------------


def _steps():
    """action.yml split into step blocks, keyed by step name. Text-based so
    the suite needs no YAML library."""
    text = ACTION.read_text()
    blocks = re.split(r"\n    - name: ", text.split("\nruns:\n", 1)[1])
    return {b.split("\n", 1)[0]: b for b in blocks[1:]}


def test_max_tokens_input_defaults_to_4096():
    m = re.search(r"\n  max-tokens:\n(.*?)\n  [a-z-]+:\n", ACTION.read_text(), re.DOTALL)
    assert m, "max-tokens input is not declared"
    assert "default: '4096'" in m.group(1)
    assert "required: false" in m.group(1)


def test_max_tokens_reaches_resolver_and_run_step():
    steps = _steps()
    wire = "INPUT_MAX_TOKENS: ${{ inputs.max-tokens }}"
    assert wire in steps["Resolve config"]
    assert wire in steps["Call provider"]


def test_reason_output_falls_through_to_the_run_step():
    text = ACTION.read_text()
    m = re.search(r"\n  reason:\n    description: (.*)\n    value: (.*)\n", text)
    assert m, "reason output is not declared"
    assert m.group(2) == "${{ steps.cfg.outputs.reason || steps.run.outputs.reason }}"
    assert "failed" in m.group(1)

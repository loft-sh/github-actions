"""read_input(): inline input plus input-file, and the fail-soft path when
the file cannot be read. input-file is how callers pass data past the
128 KiB per-variable env limit, so the file path must never end the step
with a non-zero exit."""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "run.py"


@pytest.fixture
def run(monkeypatch, tmp_path):
    out = tmp_path / "github_output"
    out.write_text("")
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    monkeypatch.delenv("INPUT_INPUT", raising=False)
    monkeypatch.delenv("INPUT_INPUT_FILE", raising=False)
    spec = importlib.util.spec_from_file_location("ai_step_run_input", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.github_output = out
    return mod


def test_inline_input_only(run, monkeypatch):
    monkeypatch.setenv("INPUT_INPUT", "inline")
    assert run.read_input() == "inline"


def test_empty_when_nothing_set(run):
    assert run.read_input() == ""


def test_file_only(run, monkeypatch, tmp_path):
    f = tmp_path / "in.json"
    f.write_text('{"prs": []}')
    monkeypatch.setenv("INPUT_INPUT_FILE", str(f))
    assert run.read_input() == '{"prs": []}'


def test_inline_then_file(run, monkeypatch, tmp_path):
    f = tmp_path / "in.txt"
    f.write_text("from file")
    monkeypatch.setenv("INPUT_INPUT", "inline")
    monkeypatch.setenv("INPUT_INPUT_FILE", str(f))
    assert run.read_input() == "inline\n\nfrom file"


def test_file_larger_than_env_limit(run, monkeypatch, tmp_path):
    big = "a" * (200 * 1024)
    f = tmp_path / "big.txt"
    f.write_text(big)
    monkeypatch.setenv("INPUT_INPUT_FILE", str(f))
    assert run.read_input() == big


def test_missing_file_fails_soft(run, monkeypatch, tmp_path):
    monkeypatch.setenv("INPUT_INPUT_FILE", str(tmp_path / "absent.json"))
    with pytest.raises(SystemExit) as exc:
        run.read_input()
    assert exc.value.code == 0
    out = run.github_output.read_text()
    assert "conclusion=failed" in out
    assert "result<<AISTEP_EOF\n\nAISTEP_EOF" in out
    # the reason output carries the cause so a caller need not read the log
    assert "reason=input-file could not be read" in out


def test_invalid_utf8_file_is_read_with_replacement(run, monkeypatch, tmp_path):
    # a stray non-UTF-8 byte must not end the step with a traceback and
    # exit 1: the bytes decode to U+FFFD and the model reads the rest
    f = tmp_path / "latin1.txt"
    f.write_bytes(b"caf\xe9 and \xff\xfe tail")
    monkeypatch.setenv("INPUT_INPUT_FILE", str(f))
    assert run.read_input() == "caf\ufffd and \ufffd\ufffd tail"
    assert "conclusion=failed" not in run.github_output.read_text()


def test_invalid_utf8_file_keeps_inline_input(run, monkeypatch, tmp_path):
    f = tmp_path / "bad.bin"
    f.write_bytes(b"\x80\x81")
    monkeypatch.setenv("INPUT_INPUT", "inline")
    monkeypatch.setenv("INPUT_INPUT_FILE", str(f))
    assert run.read_input() == "inline\n\n\ufffd\ufffd"

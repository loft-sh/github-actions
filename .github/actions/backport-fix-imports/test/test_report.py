"""report.py: the comment body from the fix's notes, and the outputs it hands
sticky-pr-comment. GitHub is faked."""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src"
sys.path.insert(0, str(SRC))
spec = importlib.util.spec_from_file_location("backport_report", SRC / "report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

SCRIPT = {"rewritten": 22, "hunks": 18, "commit": "b2c250ffb0050cae", "left": {
    "pkg/a/a_test.go": "conflict markers remain", "pkg/b/b.go": "conflict markers remain"}}


def test_nothing_to_tell_means_no_comment():
    assert report.body({}) == ""
    assert report.body({"script": {"rewritten": 0, "hunks": 0, "commit": "", "left": {}}}) == ""


def test_fix_and_leftovers():
    text = report.body({"script": SCRIPT})
    assert "fixed in b2c250ffb0 (22 file(s) rewritten, 18 import conflict(s) resolved)" in text
    assert "  - `pkg/a/a_test.go`: conflict markers remain" in text
    assert "  - `pkg/b/b.go`: conflict markers remain" in text


def test_only_leftovers():
    text = report.body({"script": {"rewritten": 0, "hunks": 0, "commit": "",
                                   "left": {"pkg/b/b.go": "conflict markers remain"}}})
    assert "Module paths" not in text and "`pkg/b/b.go`" in text


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "output"))
    monkeypatch.setenv("BACKPORT_BRANCH", "backport/release-4.12/pr-1")
    monkeypatch.setattr(report.fix, "backport_pr", lambda branch: 42)
    monkeypatch.setattr(report.fix, "github", lambda method, path, body=None: {"login": "acme-bot"})
    return tmp_path


def test_main_hands_sticky_pr_comment_its_inputs(env):
    (env / report.fix.NOTES_FILE).write_text(json.dumps({"script": SCRIPT}))
    assert report.main() == 0
    out = (env / "output").read_text()
    assert out.startswith("body<<EOF_") and "### Backport fix-imports" in out
    assert "pr-number=42\n" in out and "author=acme-bot\n" in out


def test_main_without_notes_writes_nothing(env):
    assert report.main() == 0
    assert not (env / "output").exists()


def test_main_without_a_pr_writes_nothing(env, monkeypatch):
    (env / report.fix.NOTES_FILE).write_text(json.dumps({"script": SCRIPT}))
    monkeypatch.setattr(report.fix, "backport_pr", lambda branch: None)
    assert report.main() == 0
    assert not (env / "output").exists()


def test_main_never_fails(env, monkeypatch):
    (env / report.fix.NOTES_FILE).write_text(json.dumps({"script": SCRIPT}))

    def boom(branch):
        raise OSError("HTTP Error 500")

    monkeypatch.setattr(report.fix, "backport_pr", boom)
    assert report.main() == 0

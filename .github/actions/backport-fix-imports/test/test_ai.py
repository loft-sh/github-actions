"""ai.py: hunk parsing, answer splicing, and prepare/apply against a real
throwaway Go module with a local bare remote. The model is never called: the
tests hand apply the JSON ai-step would return. apply runs real gofmt and
go vet, so those tests skip without a Go toolchain."""
from __future__ import annotations

import importlib.util
import json
import shutil
import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src"
sys.path.insert(0, str(SRC))
spec = importlib.util.spec_from_file_location("backport_ai", SRC / "ai.py")
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)

from test_fix import API_V4, commit_all, git, push_backport, remote_file, repo, write  # noqa: E402,F401

needs_go = pytest.mark.skipif(not (shutil.which("go") and shutil.which("gofmt")), reason="Go toolchain not installed")

CONFLICT = """package peer

func Pick() int {
<<<<<<< HEAD
	return 4
=======
	return five()
>>>>>>> abc123 (feat: x (#1))
}
"""
GOOD = {"resolvable": True, "code": "\treturn 4", "reason": "five() does not exist on the release branch"}
BAD = {"resolvable": True, "code": "\treturn five()", "reason": "kept the backported call"}


@pytest.fixture
def backport(repo, monkeypatch):
    """The fixture repo as a buildable module, with one Go conflict pushed on the backport branch."""
    write(repo, f"{API_V4}/go.mod", "module example.com/acme/api/v4\n\ngo 1.22\n")
    write(repo, "pkg/peer/pick.go", CONFLICT)
    push_backport(repo)
    git(repo, "fetch", "-q", "origin")
    monkeypatch.setenv("RUNNER_TEMP", str(repo.parent))
    monkeypatch.setenv("GOFLAGS", "-mod=mod")
    monkeypatch.setenv("GOTOOLCHAIN", "local")
    return repo


def prepared(repo: Path) -> Path:
    ai.prepare()
    out = dict(l.split("=", 1) for l in (repo.parent / "output").read_text().splitlines())
    return Path(out["input-file"])


def apply(monkeypatch, input_file: Path, answers: dict[str, dict]) -> None:
    monkeypatch.setenv("INPUT_FILE", str(input_file))
    monkeypatch.setenv("AI_RESULT", json.dumps({"resolutions": [{"id": k, **v} for k, v in answers.items()]}))
    ai.apply()


# -- parsing and splicing ---------------------------------------------------

def test_spans_find_complete_blocks_only():
    lines = ["a", "<<<<<<< HEAD", "x", "=======", "y", ">>>>>>> c", "b", "<<<<<<< HEAD", "z"]
    assert ai.spans(lines) == [(1, 5)]


def test_resolve_file_replaces_every_block():
    text = CONFLICT + CONFLICT.replace("package peer\n", "")
    out = ai.resolve_file(text, {"f.go#0": GOOD, "f.go#1": GOOD}, "f.go")
    assert out is not None and out.count("return 4") == 2 and "<<<<<<<" not in out


@pytest.mark.parametrize("answers", [
    {},
    {"f.go#0": {**GOOD, "resolvable": False}},
    {"f.go#0": {**GOOD, "code": "<<<<<<< HEAD\n\treturn 4"}},
    {"f.go#0": {**GOOD, "code": "\treturn 4\n======="}},
    {"f.go#0": {**GOOD, "code": None}},
])
def test_resolve_file_refuses_missing_or_unusable_answers(answers):
    assert ai.resolve_file(CONFLICT, answers, "f.go") is None


def test_partial_answers_leave_the_file():
    text = CONFLICT + CONFLICT.replace("package peer\n", "")
    assert ai.resolve_file(text, {"f.go#0": GOOD}, "f.go") is None


# -- prepare ----------------------------------------------------------------

def test_prepare_sends_conflicted_go_files_whole(backport):
    payload = json.loads(prepared(backport).read_text())
    assert payload["release_module"] == "example.com/acme/app/v4"
    [f] = payload["files"]
    assert f["file"] == "pkg/peer/pick.go" and f["ids"] == ["pkg/peer/pick.go#0"]
    assert f["content"] == CONFLICT


def test_prepare_with_no_go_conflicts_sets_nothing(repo):
    write(repo, "chart/values.yaml", "<<<<<<< HEAD\na: 1\n=======\na: 2\n>>>>>>> c\n")
    push_backport(repo)
    git(repo, "fetch", "-q", "origin")
    ai.prepare()
    assert not (repo.parent / "output").exists()


def test_prepare_over_the_cap_sets_nothing(backport, monkeypatch):
    monkeypatch.setattr(ai, "MAX_HUNKS", 0)
    ai.prepare()
    assert not (backport.parent / "output").exists()


# -- apply ------------------------------------------------------------------

@needs_go
def test_answer_that_vets_is_committed_and_pushed(backport, monkeypatch):
    apply(monkeypatch, prepared(backport), {"pkg/peer/pick.go#0": GOOD})
    content = remote_file(backport, "pkg/peer/pick.go")
    assert "return 4" in content and "<<<<<<<" not in content
    assert git(backport, "log", "-1", "--format=%s", "origin/backport/release-4.12/pr-1") == \
        "fix(backport): resolve conflicts with ai"


@needs_go
def test_answer_that_does_not_compile_is_reverted(backport, monkeypatch):
    before = git(backport, "rev-parse", "origin/backport/release-4.12/pr-1")
    apply(monkeypatch, prepared(backport), {"pkg/peer/pick.go#0": BAD})
    git(backport, "fetch", "-q", "origin")
    assert git(backport, "rev-parse", "origin/backport/release-4.12/pr-1") == before
    assert (backport / "pkg/peer/pick.go").read_text() == CONFLICT


@needs_go
def test_package_with_another_conflicted_file_is_not_committed(backport, monkeypatch):
    input_file = prepared(backport)
    write(backport, "pkg/peer/other.go", CONFLICT.replace("Pick", "Other"))
    apply(monkeypatch, input_file, {"pkg/peer/pick.go#0": GOOD})
    assert (backport / "pkg/peer/pick.go").read_text() == CONFLICT


def test_file_changed_since_prepare_is_left(backport, monkeypatch):
    input_file = prepared(backport)
    write(backport, "pkg/peer/pick.go", CONFLICT + "\n// edited\n")
    apply(monkeypatch, input_file, {"pkg/peer/pick.go#0": GOOD})
    assert (backport / "pkg/peer/pick.go").read_text() == CONFLICT + "\n// edited\n"


@pytest.mark.parametrize("result", ["", "not json", '{"resolutions": "nope"}'])
def test_garbage_result_changes_nothing_and_never_fails(backport, monkeypatch, result):
    input_file = prepared(backport)
    monkeypatch.setenv("INPUT_FILE", str(input_file))
    monkeypatch.setenv("AI_RESULT", result)
    monkeypatch.setattr(sys, "argv", ["ai.py", "apply"])
    assert ai.main() == 0
    assert (backport / "pkg/peer/pick.go").read_text() == CONFLICT

"""ai.py: hunk parsing, answer splicing, and prepare/apply against a real
throwaway Go module with a local bare remote. The model is never called: the
tests hand apply the JSON ai-step would return. apply runs real gofmt and
go vet, so those tests skip without a Go toolchain."""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
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
    monkeypatch.setenv("GITHUB_REPOSITORY", "acme/app")
    monkeypatch.setenv("GH_TOKEN", "test-token")
    return repo


@pytest.fixture
def gh(backport, monkeypatch):
    """Fake GitHub API: records label calls with the remote tip at that moment."""
    calls = []

    def github(method, path, body=None):
        tip = git(backport, "ls-remote", "origin", "refs/heads/backport/release-4.12/pr-1").split()[0]
        calls.append((method, path, body, tip))
        return {}

    monkeypatch.setattr(ai.fix, "backport_pr", lambda branch: 42)
    monkeypatch.setattr(ai.fix, "github", github)
    return calls


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


def test_prepare_never_sends_vendored_code(repo):
    write(repo, "vendor/example.com/lib/lib.go", CONFLICT)
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
def test_answer_that_vets_is_committed_and_pushed(backport, monkeypatch, gh):
    before = git(backport, "rev-parse", "origin/backport/release-4.12/pr-1")
    apply(monkeypatch, prepared(backport), {"pkg/peer/pick.go#0": GOOD})
    # The label lands while the remote still has the old tip: before the AI commit.
    assert gh == [("POST", "/repos/acme/app/issues/42/labels", {"labels": ["backport-ai-resolved"]}, before)]
    notes = json.loads((backport.parent / ai.fix.NOTES_FILE).read_text())
    assert notes["ai"]["committed"] == ["pkg/peer/pick.go"] and notes["ai"]["commit"]
    content = remote_file(backport, "pkg/peer/pick.go")
    assert "return 4" in content and "<<<<<<<" not in content
    assert git(backport, "log", "-1", "--format=%s", "origin/backport/release-4.12/pr-1") == \
        "fix(backport): resolve conflicts with ai"


@needs_go
@pytest.mark.parametrize("failure", ["no pr", "label error"])
def test_ai_commit_is_not_pushed_unless_the_pr_is_labeled(backport, monkeypatch, failure):
    def refuse(*args, **kwargs):
        raise OSError("HTTP Error 403: Forbidden")

    if failure == "no pr":
        monkeypatch.setattr(ai.fix, "backport_pr", lambda branch: None)
    else:
        monkeypatch.setattr(ai.fix, "backport_pr", lambda branch: 42)
        monkeypatch.setattr(ai.fix, "github", refuse)
    before = git(backport, "rev-parse", "origin/backport/release-4.12/pr-1")
    input_file = prepared(backport)
    monkeypatch.setenv("INPUT_FILE", str(input_file))
    monkeypatch.setenv("AI_RESULT", json.dumps({"resolutions": [{"id": "pkg/peer/pick.go#0", **GOOD}]}))
    monkeypatch.setattr(sys, "argv", ["ai.py", "apply"])
    assert ai.main() == 0
    git(backport, "fetch", "-q", "origin")
    assert git(backport, "rev-parse", "origin/backport/release-4.12/pr-1") == before


def test_go_tools_never_see_the_push_token(backport, monkeypatch):
    seen = []

    def run(cmd, **kwargs):
        seen.append((cmd[0], kwargs.get("env")))
        return subprocess.CompletedProcess(cmd, 1, "", "stop here")

    monkeypatch.setattr(ai.subprocess, "run", run)
    ai.vet("./pkg/peer")
    monkeypatch.setattr(ai.fix.subprocess, "run", run)
    monkeypatch.setattr(ai.fix.shutil, "which", lambda name: "/usr/bin/" + name)
    with pytest.raises(RuntimeError):
        ai.fix.gofmt(["pkg/peer/pick.go"])
    assert [name for name, _ in seen] == ["go", "gofmt"]
    for _, env in seen:
        assert env is not None and "GH_TOKEN" not in env


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


def conflict(package: str, good: str, bad: str, header: str = "", imports: str = "", name: str = "Pick") -> str:
    return (f"{header}package {package}\n\n{imports}func {name}() int {{\n<<<<<<< HEAD\n\treturn {good}\n=======\n"
            f"\treturn {bad}\n>>>>>>> abc123 (feat: x (#1))\n}}\n")


@needs_go
def test_conflict_in_a_nested_module_is_vetted_from_that_module(backport, monkeypatch, gh):
    # A module wired in by a replace, with no go.work: go vet must run from the module itself.
    path = f"{API_V4}/types/pick.go"
    write(backport, path, conflict("types", "4", "five()"))
    push_backport(backport)
    apply(monkeypatch, prepared(backport), {f"{path}#0": GOOD})
    notes = json.loads((backport.parent / ai.fix.NOTES_FILE).read_text())
    assert path in notes["ai"]["committed"], notes["ai"]["declined"]


@needs_go
def test_package_is_rechecked_when_a_package_it_imports_is_reverted(backport, monkeypatch, gh):
    # pkg/a passes go vet against z's resolved source (z's tests are not compiled for a).
    # pkg/z then fails go vet on its broken test file and is reverted in the same pass,
    # so pkg/a must be checked again and not committed against the reverted z.
    write(backport, "pkg/a/a.go", conflict("a", "z.Pick()", "z.Pick() + 1",
                                           imports='import "example.com/acme/app/v4/pkg/z"\n\n'))
    write(backport, "pkg/z/z.go", conflict("z", "4", "five()"))
    write(backport, "pkg/z/z_test.go", "package z\n\nvar _ = missingOnRelease\n")
    push_backport(backport)
    before = git(backport, "rev-parse", "origin/backport/release-4.12/pr-1")
    apply(monkeypatch, prepared(backport), {"pkg/a/a.go#0": {**GOOD, "code": "\treturn z.Pick()"},
                                            "pkg/z/z.go#0": GOOD, "pkg/peer/pick.go#0": BAD})
    git(backport, "fetch", "-q", "origin")
    assert git(backport, "rev-parse", "origin/backport/release-4.12/pr-1") == before
    assert "<<<<<<<" in (backport / "pkg/a/a.go").read_text()


@needs_go
def test_file_the_runner_does_not_build_is_never_committed(backport, monkeypatch, gh):
    # go vet skips files excluded by build constraints, so an answer there is never type-checked.
    path = "pkg/peer/pick_never.go"
    write(backport, path, conflict("peer", "4", "five()", "//go:build never\n\n", name="PickNever"))
    push_backport(backport)
    before = git(backport, "rev-parse", "origin/backport/release-4.12/pr-1")
    apply(monkeypatch, prepared(backport), {f"{path}#0": BAD, "pkg/peer/pick.go#0": GOOD})
    git(backport, "fetch", "-q", "origin")
    assert git(backport, "rev-parse", "origin/backport/release-4.12/pr-1") == before
    assert "<<<<<<<" in (backport / path).read_text()


@needs_go
def test_gofmt_failure_with_no_output_is_declined_not_raised(backport, monkeypatch, gh):
    real = ai.subprocess.run

    def run(cmd, **kwargs):
        if cmd[0] == "gofmt":
            return subprocess.CompletedProcess(cmd, 2, "", "")
        return real(cmd, **kwargs)

    monkeypatch.setattr(ai.subprocess, "run", run)
    apply(monkeypatch, prepared(backport), {"pkg/peer/pick.go#0": GOOD})
    notes = json.loads((backport.parent / ai.fix.NOTES_FILE).read_text())
    assert notes["ai"]["committed"] == [] and "pkg/peer/pick.go" in notes["ai"]["declined"]
    assert (backport / "pkg/peer/pick.go").read_text() == CONFLICT


@needs_go
def test_file_go_drops_by_name_is_never_committed(backport, monkeypatch, gh):
    # go/build skips _x.go and .x.go without listing them anywhere, so go vet never sees them.
    path = "pkg/peer/_template.go"
    write(backport, path, conflict("peer", "4", "five()", name="Template"))
    push_backport(backport)
    before = git(backport, "rev-parse", "origin/backport/release-4.12/pr-1")
    apply(monkeypatch, prepared(backport), {f"{path}#0": BAD, "pkg/peer/pick.go#0": GOOD})
    git(backport, "fetch", "-q", "origin")
    assert git(backport, "rev-parse", "origin/backport/release-4.12/pr-1") == before
    assert "<<<<<<<" in (backport / path).read_text()


def test_non_string_reason_is_declined_not_raised(backport, monkeypatch):
    apply(monkeypatch, prepared(backport), {"pkg/peer/pick.go#0": {"resolvable": False, "reason": ["a", 1]}})
    notes = json.loads((backport.parent / ai.fix.NOTES_FILE).read_text())
    assert "pkg/peer/pick.go" in notes["ai"]["declined"]


@needs_go
def test_answers_left_unchecked_when_time_runs_out(backport, monkeypatch, gh):
    monkeypatch.setattr(ai, "CHECK_BUDGET", 0)
    apply(monkeypatch, prepared(backport), {"pkg/peer/pick.go#0": GOOD})
    notes = json.loads((backport.parent / ai.fix.NOTES_FILE).read_text())
    assert notes["ai"]["committed"] == [] and "time" in notes["ai"]["declined"]["pkg/peer/pick.go"]
    assert (backport / "pkg/peer/pick.go").read_text() == CONFLICT


def test_reason_stays_on_one_line(backport, monkeypatch, capsys):
    reason = "needs x\n::error::injected\n- and a bullet"
    apply(monkeypatch, prepared(backport), {"pkg/peer/pick.go#0": {"resolvable": False, "reason": reason}})
    notes = json.loads((backport.parent / ai.fix.NOTES_FILE).read_text())
    assert "\n" not in notes["ai"]["declined"]["pkg/peer/pick.go"]
    assert not any(l.startswith("::error::") for l in capsys.readouterr().out.splitlines())


@needs_go
def test_failed_push_says_the_label_stays(backport, monkeypatch, gh, capsys):
    real = ai.fix.git

    def git_(*args, **kwargs):
        if args[0] == "push":
            raise RuntimeError("git push failed: ! [rejected] (fetch first)\nhint: pull first")
        return real(*args, **kwargs)

    monkeypatch.setattr(ai.fix, "git", git_)
    monkeypatch.setenv("INPUT_FILE", str(prepared(backport)))
    monkeypatch.setenv("AI_RESULT", json.dumps({"resolutions": [{"id": "pkg/peer/pick.go#0", **GOOD}]}))
    monkeypatch.setattr(sys, "argv", ["ai.py", "apply"])
    assert ai.main() == 0
    warning = [l for l in capsys.readouterr().out.splitlines() if l.startswith("::warning::backport AI pass failed")]
    assert warning and "backport-ai-resolved label stays on" in warning[0] and "rejected" in warning[0]

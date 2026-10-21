"""fix.py: the go.mod mapping, the import-hunk resolver, and full runs against
real throwaway git repos with a local bare remote. No network, no tokens."""
from __future__ import annotations

import importlib.util
import shutil
import subprocess
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "fix.py"


def load():
    spec = importlib.util.spec_from_file_location("backport_fix_imports", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fix = load()

V4_GOMOD = """module example.com/acme/app/v4

go 1.26

require example.com/acme/api/v4 v4.0.0

replace example.com/acme/api/v4 => ./staging/src/example.com/acme/api/v4
"""
V5_GOMOD = V4_GOMOD.replace("/v4", "/v5")
API_V4 = "staging/src/example.com/acme/api/v4"
API_V5 = "staging/src/example.com/acme/api/v5"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def write(repo: Path, path: str, text: str) -> None:
    (repo / path).parent.mkdir(parents=True, exist_ok=True)
    (repo / path).write_text(text)


def commit_all(repo: Path, subject: str) -> None:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", subject)


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """A clone with main on v5 and release-4.12 on v4, pushed to a bare remote.
    Returns the clone; tests build the backport branch on top of release-4.12."""
    for key, value in {"GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
                       "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
                       "GIT_CONFIG_GLOBAL": str(tmp_path / "gitconfig")}.items():
        monkeypatch.setenv(key, value)
    monkeypatch.delenv("GH_TOKEN", raising=False)
    remote = tmp_path / "remote.git"
    subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
    work = tmp_path / "work"
    subprocess.run(["git", "init", "-q", "-b", "release-4.12", str(work)], check=True)
    write(work, "go.mod", V4_GOMOD)
    write(work, f"{API_V4}/types/types.go", "package types\n")
    write(work, "pkg/peer/peer.go", 'package peer\n\nimport (\n\t"fmt"\n\n\t"example.com/acme/app/v4/pkg/util"\n)\n\nfunc A() { fmt.Println(util.X) }\n')
    commit_all(work, "release line")
    git(work, "checkout", "-q", "-b", "main")
    write(work, "go.mod", V5_GOMOD)
    git(work, "mv", API_V4, API_V5)
    commit_all(work, "refactor: bump go modules to v5")
    git(work, "remote", "add", "origin", str(remote))
    git(work, "push", "-q", "origin", "main", "release-4.12")
    git(work, "checkout", "-q", "-b", "backport/release-4.12/pr-1", "release-4.12")
    monkeypatch.chdir(work)
    monkeypatch.setenv("TARGET_BRANCH", "release-4.12")
    monkeypatch.setenv("BACKPORT_BRANCH", "backport/release-4.12/pr-1")
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "output"))
    return work


def push_backport(repo: Path) -> None:
    commit_all(repo, "backport commit")
    git(repo, "push", "-q", "origin", "backport/release-4.12/pr-1")


def outputs(repo: Path) -> dict[str, str]:
    lines = (repo.parent / "output").read_text().splitlines()
    return dict(l.split("=", 1) for l in lines)


def remote_file(repo: Path, path: str) -> str:
    git(repo, "fetch", "-q", "origin")
    return git(repo, "show", f"origin/backport/release-4.12/pr-1:{path}")


# -- mapping ---------------------------------------------------------------

def test_mapping_covers_module_line_and_local_replaces():
    paths, dirs = fix.module_mapping(V5_GOMOD, V4_GOMOD)
    assert ("example.com/acme/app/v5", "example.com/acme/app/v4") in paths
    assert ("example.com/acme/api/v5", "example.com/acme/api/v4") in paths
    assert dirs == [(API_V5, API_V4)]


def test_mapping_ignores_third_party_majors():
    src = V5_GOMOD + "require example.com/other/lib/v3 v3.0.0\n"
    tgt = V4_GOMOD + "require example.com/other/lib/v2 v2.0.0\n"
    paths, _ = fix.module_mapping(src, tgt)
    assert all("other" not in s for s, _ in paths)


def test_mapping_reads_replace_blocks():
    gomod = "module example.com/acme/app/v5\n\nreplace (\n\texample.com/acme/api/v5 => ./staging/api/v5\n\texample.com/x => example.com/y v1.0.0\n)\n"
    owned = fix.owned_modules(gomod)
    assert owned["example.com/acme/api"] == ("example.com/acme/api/v5", "staging/api/v5")
    assert "example.com/x" not in owned


def test_same_module_paths_map_to_nothing():
    assert fix.module_mapping(V4_GOMOD, V4_GOMOD) == ([], [])


# -- rewriting -------------------------------------------------------------

PATHS = [("example.com/acme/app/v5", "example.com/acme/app/v4")]


@pytest.mark.parametrize("text, expected", [
    ('"example.com/acme/app/v5/pkg/a"', '"example.com/acme/app/v4/pkg/a"'),
    ('"example.com/acme/app/v5"', '"example.com/acme/app/v4"'),
    ('"example.com/acme/app/v50/pkg"', '"example.com/acme/app/v50/pkg"'),
    ("// moved from example.com/acme/app/v5/pkg", "// moved from example.com/acme/app/v5/pkg"),
])
def test_rewrite_only_at_string_start_and_path_boundary(text, expected):
    assert fix.rewrite_paths(text, PATHS) == expected


@pytest.mark.parametrize("line, name", [
    ('\t"example.com/acme/app/v4/pkg/peer"', "peer"),
    ('\tstoragev1 "example.com/acme/api/v4/pkg/apis/storage/v1"', "storagev1"),
    ('\t"example.com/acme/api/v4"', "api"),
    ('\t"gopkg.in/yaml.v3"', "yaml"),
    ('\t"github.com/go-openapi/spec"', "spec"),
    ('\t"github.com/x/go-openapi"', None),
    ('\t_ "embed"', None),
    ('\t. "example.com/dot"', None),
])
def test_import_name(line, name):
    assert fix.import_name(line) == name


# -- resolving import hunks ------------------------------------------------

def conflicted(ours: list[str], theirs: list[str], body: str = "func F() {}\n") -> str:
    return "\n".join(["package p", "", "import (", '\t"fmt"', "",
                      "<<<<<<< HEAD", *ours, "=======", *theirs, ">>>>>>> abc123 (feat: x (#1))",
                      ")", "", body])


def test_import_only_hunk_takes_the_backported_side_rewritten():
    text = conflicted(
        ['\t"example.com/acme/app/v4/pkg/apply"'],
        ['\t"example.com/acme/app/v5/pkg/apply"', '\t"example.com/acme/app/v5/pkg/backup"'],
        "func F() { apply.X(); backup.Y() }\n")
    out, resolved = fix.resolve_import_hunks(text, PATHS)
    assert resolved == 1
    assert not fix.has_markers(out)
    assert '"example.com/acme/app/v4/pkg/backup"' in out
    assert out.count('"example.com/acme/app/v4/pkg/apply"') == 1
    assert "v5" not in out


def test_target_only_import_kept_while_used_dropped_when_not():
    text = conflicted(
        ['\t"example.com/acme/app/v4/pkg/legacy"', '\t"example.com/acme/app/v4/pkg/gone"'],
        ['\t"example.com/acme/app/v5/pkg/apply"'],
        "func F() { legacy.Run(); apply.X() }\n")
    out, _ = fix.resolve_import_hunks(text, PATHS)
    assert '"example.com/acme/app/v4/pkg/legacy"' in out
    assert "pkg/gone" not in out


def test_target_only_import_with_unknown_name_is_kept():
    text = conflicted(['\t"github.com/x/go-openapi"'], ['\t"example.com/acme/app/v5/pkg/apply"'])
    out, _ = fix.resolve_import_hunks(text, PATHS)
    assert '"github.com/x/go-openapi"' in out


def test_diff3_base_section_is_ignored():
    text = conflicted(
        ['\t"example.com/acme/app/v4/pkg/a"', "||||||| base", '\t"example.com/acme/app/v4/pkg/old"'],
        ['\t"example.com/acme/app/v5/pkg/a"'], "func F() { a.X() }\n")
    out, resolved = fix.resolve_import_hunks(text, PATHS)
    assert resolved == 1
    assert "pkg/old" not in out and "|||||||" not in out


def test_code_hunk_is_left_alone():
    text = "\n".join(["package p", "", "func F() {", "<<<<<<< HEAD", "\ta()", "=======", "\tb()",
                      ">>>>>>> abc123", "}", ""])
    out, resolved = fix.resolve_import_hunks(text, PATHS)
    assert resolved == 0 and out == text


def test_import_lines_outside_an_import_block_are_left_alone():
    text = "\n".join(["package p", "", "var s = []string{", "<<<<<<< HEAD", '\t"a"', "=======", '\t"b"',
                      ">>>>>>> abc123", "}", ""])
    _, resolved = fix.resolve_import_hunks(text, PATHS)
    assert resolved == 0


def test_unterminated_hunk_is_left_alone():
    text = "package p\n<<<<<<< HEAD\n\"a\"\n"
    assert fix.resolve_import_hunks(text, PATHS) == (text, 0)


# -- full runs -------------------------------------------------------------

def test_clean_pick_with_source_imports_is_rewritten_and_pushed(repo):
    write(repo, "pkg/peer/peer_test.go", 'package peer\n\nimport (\n\t"testing"\n\n\tstoragev1 "example.com/acme/api/v5/pkg/apis/storage/v1"\n\t"example.com/acme/app/v5/pkg/peer/networkpeer"\n)\n\nfunc TestX(t *testing.T) { _ = storagev1.X; networkpeer.Y() }\n')
    push_backport(repo)
    assert fix.main() == 0
    out = outputs(repo)
    assert out["conclusion"] == "fixed"
    assert out["files-changed"] == "1"
    content = remote_file(repo, "pkg/peer/peer_test.go")
    assert '"example.com/acme/api/v4/pkg/apis/storage/v1"' in content
    assert '"example.com/acme/app/v4/pkg/peer/networkpeer"' in content
    assert git(repo, "log", "-1", "--format=%s", "origin/backport/release-4.12/pr-1") == "fix(backport): use release-4.12 module paths"


def test_untouched_files_are_not_rewritten(repo):
    # A v5 path in a file the backport did not change is not ours to touch.
    write(repo, "pkg/other/other.go", 'package other\n\nimport _ "example.com/acme/app/v5/pkg/x"\n')
    commit_all(repo, "pre-existing")
    git(repo, "push", "-q", "origin", "HEAD:release-4.12")
    write(repo, "pkg/peer/new.go", 'package peer\n\nimport "example.com/acme/app/v5/pkg/util"\n\nvar _ = util.X\n')
    push_backport(repo)
    fix.main()
    assert '"example.com/acme/app/v5/pkg/x"' in remote_file(repo, "pkg/other/other.go")
    assert '"example.com/acme/app/v4/pkg/util"' in remote_file(repo, "pkg/peer/new.go")


def test_file_added_under_source_staging_dir_is_moved(repo):
    write(repo, f"{API_V5}/types/extra.go", 'package types\n\nimport "example.com/acme/api/v5/pkg/x"\n\nvar _ = x.Y\n')
    push_backport(repo)
    fix.main()
    assert outputs(repo)["conclusion"] == "fixed"
    tree = git(repo, "ls-tree", "-r", "--name-only", "origin/backport/release-4.12/pr-1")
    assert f"{API_V4}/types/extra.go" in tree
    assert API_V5 not in tree
    assert '"example.com/acme/api/v4/pkg/x"' in remote_file(repo, f"{API_V4}/types/extra.go")


def test_import_conflict_resolved_code_conflict_counted(repo):
    write(repo, "pkg/peer/peer.go", conflicted(
        ['\t"example.com/acme/app/v4/pkg/util"'],
        ['\t"example.com/acme/app/v5/pkg/util"', '\t"example.com/acme/app/v5/pkg/backup"'],
        "func A() { fmt.Println(util.X); backup.Y() }\n").replace("package p", "package peer"))
    write(repo, "pkg/peer/code.go", "package peer\n\nfunc B() {\n<<<<<<< HEAD\n\ta()\n=======\n\tb()\n>>>>>>> abc123\n}\n")
    push_backport(repo)
    fix.main()
    out = outputs(repo)
    assert out["conclusion"] == "fixed"
    assert out["hunks-resolved"] == "1"
    assert out["conflicts-remaining"] == "1"
    assert not fix.has_markers(remote_file(repo, "pkg/peer/peer.go"))
    assert fix.has_markers(remote_file(repo, "pkg/peer/code.go"))


@pytest.mark.skipif(not shutil.which("gofmt"), reason="gofmt not installed")
def test_resolved_import_block_is_gofmt_sorted(repo):
    write(repo, "pkg/peer/peer.go", conflicted(
        ['\t"example.com/acme/app/v4/pkg/util"'],
        ['\t"example.com/acme/app/v5/pkg/zeta"', '\t"example.com/acme/app/v5/pkg/alpha"'],
        "func A() { fmt.Println(util.X, zeta.X, alpha.X) }\n").replace("package p", "package peer"))
    push_backport(repo)
    fix.main()
    content = remote_file(repo, "pkg/peer/peer.go")
    assert content.index("pkg/alpha") < content.index("pkg/util") < content.index("pkg/zeta")


def test_second_run_is_a_no_op(repo):
    write(repo, "pkg/peer/new.go", 'package peer\n\nimport "example.com/acme/app/v5/pkg/util"\n\nvar _ = util.X\n')
    push_backport(repo)
    fix.main()
    head = git(repo, "rev-parse", "origin/backport/release-4.12/pr-1")
    (repo.parent / "output").unlink()
    fix.main()
    assert outputs(repo)["conclusion"] == "unchanged"
    git(repo, "fetch", "-q", "origin")
    assert git(repo, "rev-parse", "origin/backport/release-4.12/pr-1") == head


def test_same_module_paths_skip(repo, monkeypatch):
    git(repo, "push", "-q", "origin", "release-4.12:release-4.13")
    monkeypatch.setenv("SOURCE_BRANCH", "release-4.13")
    write(repo, "pkg/peer/new.go", "package peer\n")
    push_backport(repo)
    fix.main()
    assert outputs(repo)["conclusion"] == "skipped"


def test_push_false_leaves_the_remote_alone(repo, monkeypatch):
    monkeypatch.setenv("PUSH", "false")
    write(repo, "pkg/peer/new.go", 'package peer\n\nimport "example.com/acme/app/v5/pkg/util"\n\nvar _ = util.X\n')
    push_backport(repo)
    before = git(repo, "rev-parse", "origin/backport/release-4.12/pr-1")
    fix.main()
    out = outputs(repo)
    assert out["conclusion"] == "fixed" and out["commit"] != before
    git(repo, "fetch", "-q", "origin")
    assert git(repo, "rev-parse", "origin/backport/release-4.12/pr-1") == before


def test_missing_branch_fails_soft(repo, monkeypatch):
    monkeypatch.setenv("BACKPORT_BRANCH", "backport/release-4.12/pr-404")
    assert fix.main() == 0
    out = outputs(repo)
    assert out["conclusion"] == "failed"
    assert "git fetch failed" in out["reason"]


def test_missing_inputs_skip(repo, monkeypatch):
    monkeypatch.delenv("TARGET_BRANCH")
    assert fix.main() == 0
    assert outputs(repo)["conclusion"] == "skipped"

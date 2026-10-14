"""collect.py: tag resolution against a real throwaway git repo, Linear id
extraction, the input budget, and the never-fail contract. GraphQL is
stubbed, so no network and no tokens."""
from __future__ import annotations

import importlib.util
import json
import subprocess
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "collect.py"


def load():
    spec = importlib.util.spec_from_file_location("release_summary_collect", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def commit(repo: Path, subject: str) -> str:
    git(repo, "commit", "--allow-empty", "-q", "-m", subject)
    return git(repo, "rev-parse", "HEAD")


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """v1.0.0 -> v1.1.0-next.1 -> v1.1.0-alpha.1 -> three commits -> v1.1.0-alpha.2"""
    r = tmp_path / "repo"
    r.mkdir()
    git(r, "init", "-q", "-b", "main")
    git(r, "config", "user.email", "t@example.com")
    git(r, "config", "user.name", "t")
    commit(r, "initial")
    git(r, "tag", "v1.0.0")
    commit(r, "feature branch cut")
    git(r, "tag", "v1.1.0-next.1")
    commit(r, "alpha one")
    git(r, "tag", "v1.1.0-alpha.1")
    shas = [commit(r, "feat: squash merged (#10)"),
            commit(r, "fix: rebase merged without a number"),
            commit(r, "chore: direct push")]
    git(r, "tag", "v1.1.0-alpha.2")
    monkeypatch.chdir(r)
    return r, shas


@pytest.fixture
def env(tmp_path, monkeypatch):
    out = tmp_path / "github_output"
    out.write_text("")
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))
    for k, v in {"VERSION": "v1.1.0-alpha.2", "REPOSITORY": "o/r",
                 "GH_TOKEN": "t", "HAS_ANTHROPIC_KEY": "true",
                 "HAS_SLACK_TOKEN": "true", "CHANNEL_ID": "C1",
                 "THREAD_TS": "1.2", "DRY_RUN": "false"}.items():
        monkeypatch.setenv(k, v)
    monkeypatch.delenv("PREVIOUS_TAG", raising=False)
    return out


def outputs(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)


def pr(number, title="t", body="", branch="", merged=True):
    return {"number": number, "title": title, "body": body, "url": f"https://x/pull/{number}",
            "headRefName": branch, "mergedAt": "2026-10-13T00:00:00Z" if merged else None,
            "additions": 1, "deletions": 2, "changedFiles": 1, "author": {"login": "a"},
            "labels": {"nodes": [{"name": "bug"}]}, "files": {"nodes": [{"path": "a.go"}]}}


# previous tag

def test_previous_tag_skips_next_tags(repo):
    mod = load()
    assert mod.resolve_previous_tag("v1.1.0-alpha.2", "") == "v1.1.0-alpha.1"
    assert mod.resolve_previous_tag("v1.1.0-alpha.1", "") == "v1.0.0"


def test_previous_tag_override(repo):
    assert load().resolve_previous_tag("v1.1.0-alpha.2", "v1.0.0") == "v1.0.0"


def test_previous_tag_override_missing_skips(repo, env):
    with pytest.raises(SystemExit) as exc:
        load().resolve_previous_tag("v1.1.0-alpha.2", "v9.9.9")
    assert exc.value.code == 0
    assert outputs(env)["proceed"] == "false"


def test_first_release_skips(repo, env):
    with pytest.raises(SystemExit) as exc:
        load().resolve_previous_tag("v1.0.0", "")
    assert exc.value.code == 0
    assert "nothing to compare" in outputs(env)["reason"]


# linear ids

@pytest.mark.parametrize("title,body,branch,want", [
    ("ENG-12838 redfish explorer", "", "", ["ENG-12838"]),
    ("[ENGUI-1] x", "", "", ["ENGUI-1"]),
    ("feat: x", "Closes ENGCP-1606", "", ["ENGCP-1606"]),
    ("feat: x", "fixes: devops-12\nResolves ENG-3", "", ["DEVOPS-12", "ENG-3"]),
    ("feat: x", "see https://linear.app/loft/issue/ENGPLAT-947/obs", "", ["ENGPLAT-947"]),
    ("feat: x", "", "devops-1641/ai-release-changelog", ["DEVOPS-1641"]),
    ("feat: x", "", "renovate/go-1.x", []),
    ("CVE-2026-1234 bump", "Fixes CVE-2026-1234", "", []),
    ("ENG-1 a", "Closes ENG-1", "eng-1/a", ["ENG-1"]),
    ("feat: x", "mentions ENG-5 without a keyword", "", []),
])
def test_linear_ids(title, body, branch, want):
    assert load().linear_ids(title, body, branch) == want


def test_clean_body_drops_template_comments():
    body = "<!-- Brief summary -->\nReal text\n\n\n\n<!--\nmulti\n-->More"
    assert load().clean_body(body) == "Real text\n\nMore"


# budget

def test_fit_budget_trims_bodies_but_keeps_titles():
    mod = load()
    doc = {"pull_requests": [{"number": i, "title": f"t{i}", "body": "x" * 50_000}
                             for i in range(20)]}
    out = mod.fit_budget(doc, limit=100_000)
    assert len(json.dumps(out)) <= 100_000
    assert all(p["title"] == f"t{p['number']}" for p in out["pull_requests"])
    assert all(p["body"].endswith("[truncated]") for p in out["pull_requests"])


def test_fit_budget_drops_bodies_as_last_resort():
    mod = load()
    doc = {"pull_requests": [{"number": i, "title": "t", "body": "x" * 5_000}
                             for i in range(100)]}
    out = mod.fit_budget(doc, limit=10_000)
    assert all(p["body"] == "" for p in out["pull_requests"])


def test_fit_budget_leaves_small_input_alone():
    mod = load()
    doc = {"pull_requests": [{"number": 1, "title": "t", "body": "short"}]}
    assert mod.fit_budget(doc)["pull_requests"][0]["body"] == "short"


# gate

@pytest.mark.parametrize("unset,needle", [
    ("HAS_SLACK_TOKEN", "slack-bot-token"),
    ("CHANNEL_ID", "channel id"),
    ("THREAD_TS", "no thread"),
])
def test_gate_skips_without_delivery_path(env, monkeypatch, unset, needle):
    monkeypatch.setenv(unset, "")
    with pytest.raises(SystemExit) as exc:
        load().gate()
    assert exc.value.code == 0
    assert needle in outputs(env)["reason"]


def test_gate_open_in_dry_run(env, monkeypatch):
    monkeypatch.setenv("DRY_RUN", "true")
    monkeypatch.setenv("THREAD_TS", "")
    load().gate()


# end to end with stubbed GraphQL

def test_main_collects_and_proceeds(repo, env):
    _, shas = repo
    mod = load()
    calls = []

    def fake_graphql(query, variables, token):
        calls.append(query)
        if "associatedPullRequests" in query:
            return {"repository": {
                # git log is newest first: direct push, rebase merge, squash merge
                "c0": {"associatedPullRequests": {"nodes": []}},
                "c1": {"associatedPullRequests": {"nodes": [pr(11, merged=False), pr(12)]}},
                "c2": {"associatedPullRequests": {"nodes": [pr(10, body="Closes ENG-7")]}},
            }}
        raise AssertionError("no subject names a PR, so no lookup by number")

    mod.graphql = fake_graphql
    mod.main()
    o = outputs(env)
    assert o["proceed"] == "true"
    assert o["previous_tag"] == "v1.1.0-alpha.1"
    assert o["pr_count"] == "2"
    doc = json.loads(Path(o["input_file"]).read_text())
    assert [p["number"] for p in doc["pull_requests"]] == [12, 10]
    assert doc["commits_without_pr"][0]["subject"] == "chore: direct push"
    prs = json.loads(Path(o["prs_file"]).read_text())
    assert prs["pull_requests"][1] == {"number": 10, "url": "https://x/pull/10",
                                       "title": "t", "linear": ["ENG-7"]}
    assert len(calls) == 1


def test_main_falls_back_to_subject_pr_number(repo, env):
    mod = load()

    def fake_graphql(query, variables, token):
        if "associatedPullRequests" in query:
            return {"repository": {f"c{i}": None for i in range(3)}}
        assert "p10: pullRequest(number: 10)" in query
        return {"repository": {"p10": pr(10)}}

    mod.graphql = fake_graphql
    mod.main()
    assert outputs(env)["pr_count"] == "1"


def test_main_without_anthropic_key_collects_then_skips(repo, env, monkeypatch):
    monkeypatch.setenv("HAS_ANTHROPIC_KEY", "false")
    mod = load()
    mod.graphql = lambda q, v, t: {"repository": {f"c{i}": None for i in range(3)}} \
        if "associatedPullRequests" in q else {"repository": {}}
    with pytest.raises(SystemExit) as exc:
        mod.main()
    assert exc.value.code == 0
    o = outputs(env)
    assert o["proceed"] == "false"
    assert Path(o["input_file"]).exists()


def test_script_exits_zero_on_unexpected_error(repo, env):
    """A GraphQL outage must not fail the release: run the script as a
    process, pointing GraphQL at a closed port."""
    proc = subprocess.run(["python3", str(SRC)], capture_output=True, text=True,
                          env={**__import__("os").environ,
                               "GITHUB_GRAPHQL_URL": "http://127.0.0.1:9/graphql"},
                          timeout=60)
    assert proc.returncode == 0
    assert "collecting changes failed" in proc.stdout
    assert outputs(env)["proceed"] == "false"

"""collect.py: tag resolution against a real throwaway git repo, Linear id
extraction, the input budget, and the never-fail contract. GraphQL is
stubbed, so no network and no tokens."""
from __future__ import annotations

import http.client
import importlib.util
import io
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from email.message import Message
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


def init_repo(path: Path) -> Path:
    path.mkdir()
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.email", "t@example.com")
    git(path, "config", "user.name", "t")
    return path


def history(tmp_path, monkeypatch, *tags_per_commit):
    """One empty commit per argument, oldest first, each tagged with the tags
    given. Tags on one commit are how a release shares a commit with its rc."""
    r = init_repo(tmp_path / "history")
    for i, tags in enumerate(tags_per_commit):
        commit(r, f"commit {i}")
        for tag in tags:
            git(r, "tag", tag)
    monkeypatch.chdir(r)
    return r


@pytest.fixture
def repo(tmp_path, monkeypatch):
    """v1.0.0 -> v1.1.0-next.1 -> v1.1.0-alpha.1 -> three commits -> v1.1.0-alpha.2"""
    r = init_repo(tmp_path / "repo")
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
                 "THREAD_TS": "1700000000.000100", "DRY_RUN": "false"}.items():
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


class FakeResponse:
    """What urlopen returns: a context manager whose read() gives the JSON
    body, or raises when the body is an exception (a reset mid-read)."""

    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, *args):
        if isinstance(self.body, BaseException):
            raise self.body
        return json.dumps(self.body).encode()


def http_error(code, headers=None, body=b""):
    msg = Message()
    for key, value in (headers or {}).items():
        msg[key] = value
    return urllib.error.HTTPError("https://api.github.com/graphql", code, "reason",
                                  msg, io.BytesIO(body))


def stub_urlopen(monkeypatch, *steps):
    """Each urlopen call consumes one step: an exception to raise or a
    response to return. time.sleep is recorded instead of slept. Returns
    (requests, sleeps)."""
    calls, sleeps, queue = [], [], list(steps)

    def fake(req, timeout=None):
        calls.append(req)
        step = queue.pop(0)
        if isinstance(step, BaseException):
            raise step
        return step

    monkeypatch.setattr(urllib.request, "urlopen", fake)
    monkeypatch.setattr(time, "sleep", sleeps.append)
    return calls, sleeps


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


def test_previous_tag_prefers_the_rc_on_the_same_commit(tmp_path, monkeypatch):
    """v4.12.2 is cut from the commit of v4.12.2-rc.7; describe v4.12.2^ would
    skip it and answer rc.6, so the GA summary would repeat rc.7's changes."""
    history(tmp_path, monkeypatch, ["v4.12.1"], ["v4.12.2-rc.6"],
            ["v4.12.2-rc.7", "v4.12.2"])
    assert load().resolve_previous_tag("v4.12.2", "") == "v4.12.2-rc.7"


def test_previous_tag_same_commit_orders_numerically(tmp_path, monkeypatch):
    """rc.10 beats rc.9 and a prerelease beats an older alpha, whatever the
    order git lists them in."""
    history(tmp_path, monkeypatch, ["v1.0.0"],
            ["v1.1.0-alpha.2", "v1.1.0-rc.9", "v1.1.0-rc.10", "v1.1.0-beta.1", "v1.1.0"])
    assert load().resolve_previous_tag("v1.1.0", "") == "v1.1.0-rc.10"


def test_previous_tag_same_commit_ignores_next_tags(tmp_path, monkeypatch):
    """-next sorts above alpha, so only the exclusion keeps it out."""
    history(tmp_path, monkeypatch, ["v1.0.0"],
            ["v1.1.0-alpha.1", "v1.1.0-next.3", "v1.1.0"])
    assert load().resolve_previous_tag("v1.1.0", "") == "v1.1.0-alpha.1"


def test_previous_tag_ignores_a_higher_tag_on_the_same_commit(tmp_path, monkeypatch):
    """Resolving the rc while the release already sits on its commit must not
    compare the rc with its own release."""
    history(tmp_path, monkeypatch, ["v1.0.0"], ["v1.1.0-rc.1", "v1.1.0"])
    assert load().resolve_previous_tag("v1.1.0-rc.1", "") == "v1.0.0"


def test_previous_tag_falls_back_to_describe_without_a_shared_commit(tmp_path, monkeypatch):
    history(tmp_path, monkeypatch, ["v1.0.0"], [], ["v1.1.0"])
    assert load().resolve_previous_tag("v1.1.0", "") == "v1.0.0"


def test_previous_tag_prefers_the_release_over_its_rc_on_one_commit(tmp_path, monkeypatch):
    """v4.12.1 follows a commit carrying v4.12.0 and v4.12.0-rc.12. describe
    breaks that tie on tagger date, so an rc tagged later wins over the
    release; the tagger dates here pin that."""
    r = history(tmp_path, monkeypatch, ["v4.12.0-rc.11"], [])
    for tag, date in (("v4.12.0", "2026-01-01T00:00:00"),
                      ("v4.12.0-rc.12", "2026-01-02T00:00:00")):
        subprocess.run(["git", "-C", str(r), "tag", "-a", "-m", tag, tag], check=True,
                       capture_output=True, env={**os.environ, "GIT_COMMITTER_DATE": date})
    commit(r, "commit 2")
    git(r, "tag", "v4.12.1")
    assert git(r, "describe", "--tags", "--abbrev=0", "v4.12.1^") == "v4.12.0-rc.12"
    assert load().resolve_previous_tag("v4.12.1", "") == "v4.12.0"


def test_semver_key_orders_by_precedence():
    mod = load()
    ordered = ["v1.2.0-1", "v1.2.0-alpha", "v1.2.0-alpha.1", "v1.2.0-alpha.2",
               "v1.2.0-beta.1", "v1.2.0-rc.2", "v1.2.0-rc.9", "v1.2.0-rc.10",
               "v1.2.0", "v1.2.1", "v1.10.0", "v2.0.0-alpha.1", "v2.0.0"]
    assert sorted(ordered[5:] + ordered[:5], key=mod.semver_key) == ordered


@pytest.mark.parametrize("tag", ["v1.2", "v1.2.x", "vnext", "latest", "v1.2.3.4"])
def test_semver_key_rejects_what_is_not_semver(tag):
    assert load().semver_key(tag) is None


# shallow checkout

def test_main_skips_a_shallow_checkout(repo, env, tmp_path, monkeypatch):
    """A depth-1 clone cuts git log at the shallow boundary: the range would
    come back short while the title and diffstat claim all of it."""
    source, _ = repo
    clone = tmp_path / "shallow"
    subprocess.run(["git", "clone", "-q", "--depth", "1", f"file://{source}", str(clone)],
                   check=True, capture_output=True)
    assert git(clone, "rev-parse", "--is-shallow-repository") == "true"
    monkeypatch.chdir(clone)
    mod = load()

    def no_graphql(*args):
        raise AssertionError("a shallow checkout must skip before any lookup")

    mod.graphql = no_graphql
    with pytest.raises(SystemExit) as exc:
        mod.main()
    assert exc.value.code == 0
    o = outputs(env)
    assert o["proceed"] == "false"
    assert "shallow" in o["reason"]
    assert "actions/checkout" in o["reason"]
    assert "fetch-depth: 0" in o["reason"]
    assert "fetch-tags: true" in o["reason"]


def test_full_checkout_is_not_shallow(repo):
    assert load().is_shallow() is False


# linear ids

@pytest.mark.parametrize("title,body,branch,want", [
    ("ENG-12838 redfish explorer", "", "", ["ENG-12838"]),
    ("[ENGUI-1] x", "", "", ["ENGUI-1"]),
    ("feat: x", "Closes ENGCP-1606", "", ["ENGCP-1606"]),
    ("feat: x", "fixes: DEVOPS-12\nResolves ENG-3", "", ["DEVOPS-12", "ENG-3"]),
    ("feat: x", "see https://linear.app/loft/issue/ENGPLAT-947/obs", "", ["ENGPLAT-947"]),
    ("feat: x", "", "devops-1641/ai-release-changelog", ["DEVOPS-1641"]),
    ("feat: x", "", "renovate/go-1.x", []),
    ("CVE-2026-1234 bump", "Fixes CVE-2026-1234", "", []),
    ("ENG-1 a", "Closes ENG-1", "eng-1/a", ["ENG-1"]),
    ("feat: x", "mentions ENG-5 without a keyword", "", []),
    ("fix: handle ENG-5 mid title", "", "", []),
    ("feat: x", "CLOSES ENG-1", "", ["ENG-1"]),
    ("feat: x", "see https://linear.app/loft/issue/engplat-947/obs", "", ["ENGPLAT-947"]),
    # false positives: a Go advisory id, the id half of a lowercase word,
    # branch names that only look like team-n
    ("feat: x", "Renovate: resolve GO-2026-5932", "", []),
    ("GO-2026-5932: bump golang.org/x/net", "", "", []),
    ("feat: x", "Fixes GO-2026-5932, GO-2026-5933", "", []),
    # same shape under a prefix no denylist names: the id-then-"-digits" rule
    ("ENG-2026-5932: x", "", "", []),
    ("feat: x", "Fixes ENG-2026-5932", "", []),
    ("fix(ENG-2026-5932): x", "", "", []),
    ("feat: x", "related to helm-3", "", []),
    ("feat: x", "Fixes helm-3 chart handling", "", []),
    ("feat: x", "", "bump-3/golang", []),
    ("feat: x", "", "go-2026-5932/fix", []),
    ("feat: x", "", "eng-12-34/x", []),
    ("feat: x", "", "feature/eng-12/x", []),
    ("feat: x", "", "user/eng-123-some-title", []),
    ("feat: x", "", "devops-1641/ai-release-changelog/extra", ["DEVOPS-1641"]),
    # misses: every id in a closing list, a backport tag in front, a
    # conventional-commit scope
    ("feat: x", "Fixes ENGUI-2467, ENGUI-2468", "", ["ENGUI-2467", "ENGUI-2468"]),
    ("feat: x", "Closes ENG-1, ENG-2, and ENG-3", "", ["ENG-1", "ENG-2", "ENG-3"]),
    ("feat: x", "Fixes ENG-1 and ENG-2", "", ["ENG-1", "ENG-2"]),
    ("feat: x", "Fixes ENG-1 & ENG-2", "", ["ENG-1", "ENG-2"]),
    ("feat: x", "Fixes ENG-1, but not ENG-2", "", ["ENG-1"]),
    ("feat: x", "Fixes ENG-1, ENG-2\nENG-3 is unrelated", "", ["ENG-1", "ENG-2"]),
    ("feat: x", "Closes ENG-1\nCloses ENG-2", "", ["ENG-1", "ENG-2"]),
    ("[release-4.12] ENGCP-1687 - fix x", "", "", ["ENGCP-1687"]),
    ("[release-4.12][ENGCP-1687] fix x", "", "", ["ENGCP-1687"]),
    ("[release-4.12] [ENGCP-1687] fix x", "", "", ["ENGCP-1687"]),
    ("fix(ENGCP-1606): x", "", "", ["ENGCP-1606"]),
    ("fix(ENGCP-1606)!: x", "", "", ["ENGCP-1606"]),
    ("fix(api, ENGCP-1606, ENGCP-1607): x", "", "", ["ENGCP-1606", "ENGCP-1607"]),
    ("[release-4.12] fix(ENGCP-1606): x", "", "", ["ENGCP-1606"]),
    ("fix(api): x", "", "", []),
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


@pytest.mark.parametrize("value,want", [
    ("1791973854.515449", "1791973854.515449"),
    (" 1791973854.515449 ", "1791973854.515449"),
    ("https://x.slack.com/archives/C068ZLG3QJY/p1791973854515449", "1791973854.515449"),
    ("https://x.slack.com/archives/C068ZLG3QJY/p1791973854515449?thread_ts=1791922221.968419&cid=C1",
     "1791922221.968419"),
    ("https://x.slack.com/archives/C1/p1791973854515449?cid=C1", "1791973854.515449"),
    ("not a ts", ""),
    ("", ""),
])
def test_thread_ts(value, want):
    assert load().thread_ts(value) == want


def test_gate_returns_ts_from_link(env, monkeypatch):
    monkeypatch.setenv("THREAD_TS", "https://x.slack.com/archives/C1/p1791973854515449")
    assert load().gate() == "1791973854.515449"


def test_gate_skips_unreadable_thread_ts(env, monkeypatch):
    monkeypatch.setenv("THREAD_TS", "yesterday's banner")
    with pytest.raises(SystemExit) as exc:
        load().gate()
    assert exc.value.code == 0
    assert "Copy link" in outputs(env)["reason"]


def test_gate_open_in_dry_run(env, monkeypatch):
    monkeypatch.setenv("DRY_RUN", "true")
    monkeypatch.setenv("THREAD_TS", "")
    load().gate()


# graphql transport

NOT_FOUND = {"type": "NOT_FOUND", "path": ["repository", "p128"],
             "message": "Could not resolve to a PullRequest with the number of 128."}


@pytest.mark.parametrize("code,headers,body", [
    (401, {}, b'{"message":"Bad credentials"}'),
    (403, {}, b'{"message":"Resource not accessible by personal access token"}'),
    (404, {}, b""),
    (422, {}, b""),
])
def test_graphql_permanent_http_error_fails_at_once(monkeypatch, code, headers, body):
    """A bad token or a missing repository does not heal in 12 seconds."""
    calls, sleeps = stub_urlopen(monkeypatch, http_error(code, headers, body))
    with pytest.raises(RuntimeError, match=f"HTTP {code}"):
        load().graphql("q", {}, "t")
    assert len(calls) == 1
    assert sleeps == []


@pytest.mark.parametrize("error", [
    http_error(429),
    http_error(502),
    http_error(503),
    http_error(403, {"Retry-After": "1"}),
    http_error(403, {"X-RateLimit-Remaining": "0"}),
    http_error(403, body=b'{"message":"You have exceeded a secondary rate limit."}'),
    http.client.RemoteDisconnected("Remote end closed connection without response"),
    FakeResponse(http.client.IncompleteRead(b"part")),
    urllib.error.URLError("temporary failure in name resolution"),
    TimeoutError("timed out"),
], ids=["429", "502", "503", "403-retry-after", "403-ratelimit-remaining",
        "403-secondary-rate-limit", "remote-disconnected", "incomplete-read",
        "url-error", "timeout"])
def test_graphql_retries_transient_failures(monkeypatch, error):
    calls, sleeps = stub_urlopen(monkeypatch, error,
                                 FakeResponse({"data": {"repository": {}}}))
    assert load().graphql("q", {}, "t") == {"repository": {}}
    assert len(calls) == 2
    assert sleeps == [2]


def test_graphql_gives_up_after_three_attempts_and_sleeps_between_them(monkeypatch):
    calls, sleeps = stub_urlopen(monkeypatch, *[http.client.RemoteDisconnected("reset")] * 3)
    with pytest.raises(RuntimeError, match="after 3 attempts"):
        load().graphql("q", {}, "t")
    assert len(calls) == 3
    assert sleeps == [2, 4]


def test_graphql_keeps_data_when_every_error_is_not_found(monkeypatch):
    """A (#N) subject that names an issue resolves to a null node plus a
    NOT_FOUND error; the other aliases in the batch are still good."""
    data = {"repository": {"p308": {"number": 308}, "p128": None}}
    calls, sleeps = stub_urlopen(monkeypatch,
                                 FakeResponse({"data": data, "errors": [NOT_FOUND]}))
    assert load().graphql("q", {}, "t") == data
    assert len(calls) == 1
    assert sleeps == []


def test_fetch_by_number_keeps_the_pr_when_the_other_number_is_an_issue(monkeypatch):
    data = {"repository": {"p308": pr(308), "p128": None}}
    stub_urlopen(monkeypatch, FakeResponse({"data": data, "errors": [NOT_FOUND]}))
    assert load().fetch_by_number("o/r", [128, 308], "t") == {308: pr(308)}


@pytest.mark.parametrize("payload", [
    {"data": {"repository": {"p1": None}},
     "errors": [NOT_FOUND, {"type": "FORBIDDEN", "message": "no"}]},
    {"data": {"repository": {"p1": None}}, "errors": [{"message": "Something went wrong"}]},
    {"data": {"repository": None},
     "errors": [{"type": "NOT_FOUND", "path": ["repository"],
                 "message": "Could not resolve to a Repository with the name 'o/r'."}]},
], ids=["mixed-types", "untyped", "repository-not-visible"])
def test_graphql_fails_on_any_other_error(monkeypatch, payload):
    """NOT_FOUND is only harmless for a node in the batch. Another error type,
    or a repository the token cannot see, still fails with the reason."""
    stub_urlopen(monkeypatch, *[FakeResponse(payload)] * 3)
    with pytest.raises(RuntimeError, match="GraphQL errors"):
        load().graphql("q", {}, "t")


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
    assert o["thread_ts"] == "1700000000.000100"
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
    mod.graphql = lambda q, v, t: {"repository": {
        "c0": None, "c1": None, "c2": {"associatedPullRequests": {"nodes": [pr(10)]}}}}
    with pytest.raises(SystemExit) as exc:
        mod.main()
    assert exc.value.code == 0
    o = outputs(env)
    assert o["proceed"] == "false"
    assert "Anthropic" in o["reason"]
    assert Path(o["input_file"]).exists()


def test_main_skips_when_no_commit_resolves_to_a_pr(repo, env):
    """With no PR the model can only cite nothing, render drops every item,
    and the run would end failed after an AI call spent for nothing."""
    mod = load()
    mod.graphql = lambda q, v, t: {"repository": {f"c{i}": None for i in range(3)}} \
        if "associatedPullRequests" in q else {"repository": {}}
    with pytest.raises(SystemExit) as exc:
        mod.main()
    assert exc.value.code == 0
    o = outputs(env)
    assert o["proceed"] == "false"
    assert o["reason"] == "no merged pull requests between v1.1.0-alpha.1 and v1.1.0-alpha.2"
    assert o["pr_count"] == "0"
    assert o["previous_tag"] == "v1.1.0-alpha.1"


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


def test_script_exits_zero_when_github_output_is_unwritable(repo, env, tmp_path):
    """The top-level handler writes outputs too, so a write failure there
    must not turn into a traceback and exit 1."""
    proc = subprocess.run(["python3", str(SRC)], capture_output=True, text=True,
                          env={**__import__("os").environ,
                               "GITHUB_OUTPUT": str(tmp_path),  # a directory
                               "GITHUB_GRAPHQL_URL": "http://127.0.0.1:9/graphql"},
                          timeout=60)
    assert proc.returncode == 0, proc.stderr
    assert "could not write output" in proc.stdout

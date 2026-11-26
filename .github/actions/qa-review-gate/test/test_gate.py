import importlib.util
import os
import json
import pathlib

import pytest

SRC = pathlib.Path(__file__).resolve().parents[1] / "src" / "gate.py"
spec = importlib.util.spec_from_file_location("gate", SRC)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

HEAD = "a" * 40
OTHER = "b" * 40
BOTS = gate.parse_bots(gate.DEFAULT_BOTS)


def marker(verdict="block", classes="a:0,b:1,c:2,d:0", head=HEAD, base="main"):
    return f"Panel review: 3 blocking.\n\n<!-- qa-review verdict={verdict} classes={classes} head={head} base={base} -->"


def review_event(login="loft-bot", body=None, head=HEAD):
    return {
        "review": {"user": {"login": login}, "body": marker() if body is None else body,
                   "html_url": "https://github.com/o/r/pull/1#pullrequestreview-9"},
        "pull_request": {"number": 1, "head": {"sha": head}, "base": {"ref": "main"}},
    }


def backport_pr(login="loft-bot", ref="backport/release-5.0/pr-9204"):
    return {"number": 9444, "user": {"login": login}, "head": {"sha": HEAD, "ref": ref},
            "title": "[release-5.0] test(e2e): wait for the argocd app",
            "html_url": "https://github.com/o/r/pull/9444"}


def comment_event(body, login="sowmyav27", association="MEMBER", on_pr=True):
    return {
        "issue": {"number": 1, **({"pull_request": {"url": "x"}} if on_pr else {})},
        "comment": {"body": body, "user": {"login": login}, "author_association": association,
                    "created_at": "2026-11-18T10:00:00Z",
                    "html_url": "https://github.com/o/r/pull/1#issuecomment-5"},
    }


def backport_event(pr=None, sender="loft-bot", action="opened"):
    event = {"action": action, "pull_request": pr or backport_pr(), "sender": {"login": sender}}
    if action == "synchronize":
        event["before"] = "b" * 40
    return event


def panel_review(head=HEAD, submitted_at="2026-11-18T09:00:00Z", login="loft-bot"):
    return {"user": {"login": login}, "body": marker(head=head), "submitted_at": submitted_at}


def pr_api(reviews=None, runs=()):
    """A fake gh_api for the PR lookups apply makes: the head, the PR's reviews, its pull_request
    runs as (created_at, head_sha[, PR number])."""
    def fake(args, token, payload=None):
        if args[0].endswith("/reviews"):
            return [[panel_review()] if reviews is None else reviews]
        if "/actions/runs?" in args[0]:
            assert "event=pull_request&branch=feature&created=<=2026-11-18T10:00:00Z" in args[0]
            return {"workflow_runs": [{"created_at": at, "head_sha": sha, "pull_requests": [{"number": (pr or [1])[0]}]}
                                      for at, sha, *pr in runs]}
        if "/pulls/" in args[0] and len(args) == 1:
            return {"head": {"sha": HEAD, "ref": "feature", "repo": {"full_name": "o/r"}}}
        return {}
    return fake


def test_parse_marker_reads_verdict_classes_and_head():
    assert gate.parse_marker(marker()) == ("block", {"a": 0, "b": 1, "c": 2, "d": 0}, HEAD, "main")
    assert gate.parse_marker(marker().replace(" base=main", "")) is None  # a marker without its base is no marker


def test_parse_marker_absent_returns_none():
    assert gate.parse_marker("Panel review: nothing here") is None
    assert gate.parse_marker(None) is None


@pytest.mark.parametrize("bad", [marker(verdict="maybe"), marker(classes="e:1"), marker(classes="a:x")])
def test_parse_marker_rejects_malformed(bad):
    with pytest.raises(gate.GateError):
        gate.parse_marker(bad)


def test_review_block_becomes_failure_with_class_words():
    decision = gate.decide_review(review_event(), "loft-bot", "qa-review")
    check = decision["check"]
    assert check["conclusion"] == "failure"
    assert check["head_sha"] == HEAD
    assert check["title"] == "QA review: blocked (1 weak test, 2 no test)"
    assert decision["request_qa_review"] is False


@pytest.mark.parametrize("verdict,conclusion,to_author", [
    ("pass", "success", False), ("needs_human", "action_required", True), ("not_run", "action_required", False),
])
def test_review_verdict_mapping(verdict, conclusion, to_author):
    event = review_event(body=marker(verdict=verdict, classes=""))
    decision = gate.decide_review(event, "loft-bot", "qa-review")
    assert decision["check"]["conclusion"] == conclusion
    assert decision["request_qa_review"] is False
    assert decision["assign_author"] is to_author


def review_api(check_runs=(), files=None, author="dev-x"):
    """A fake gh_api for collect_review and apply: existing qa-test-run check-runs on the head,
    the compare diff, the PR (for its author), and a log of the writes."""
    writes = []

    def fake(args, token, payload=None):
        if payload is not None:
            writes.append((args[0], payload))
            return {"id": 1}
        if "/check-runs?check_name=" in args[0]:
            return {"check_runs": list(check_runs)}
        if "/compare/" in args[0]:
            if files is None:
                raise gate.GateError("gh api compare failed: 500")
            return {"files": files}
        if "/pulls/" in args[0]:
            return {"head": {"sha": HEAD}, "base": {"ref": "main"}, "user": {"login": author}}
        return {}
    fake.writes = writes
    return fake


NEW_SPEC = [{"filename": "e2e/a.go", "patch": '@@ -1,0 +1 @@\n+\tIt("new", func() {'}]


def test_review_opens_the_test_run_check_green_when_the_pr_adds_no_spec(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", review_api(files=[]))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    assert [(c["name"], c["conclusion"]) for c in decision["checks"]] == [
        ("qa-review", "failure"), ("qa-test-run", "success")]


PLACEHOLDER = {"app": {"slug": "github-actions"}, "id": 7, "status": "completed", "conclusion": "action_required", "external_id": "qa-review-gate:scope",
               "output": {"title": "QA test run: in scope after retarget to main, the panel decides", "summary": "s"}}


def test_panel_verdict_replaces_a_scope_pass_the_retarget_job_has_not_withdrawn_yet(monkeypatch):
    # Base changed, the panel ran first: the old out-of-scope success on qa-test-run must
    # give way to the opener that waits for the newly added spec.
    scope_pass = {"app": {"slug": "github-actions"}, "id": 7, "status": "completed", "conclusion": "success", "external_id": "qa-review-gate:scope",
                  "output": {"title": "QA test run: out of scope, no QA-owned path (base main@b)", "summary": "s"}}
    api = review_api(check_runs=[scope_pass], files=NEW_SPEC)
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.collect_review(review_event(body=marker("pass")), "o/r", "tok", "loft-bot", "qa-review")
    assert [(c["name"], c["conclusion"]) for c in decision["checks"]] == [
        ("qa-review", "success"), ("qa-test-run", "action_required")]
    gate.apply(decision, "o/r", "tok", "", "https://run")
    posts = [p for a, p in api.writes if a == "repos/o/r/check-runs"]
    assert [(p["name"], p["conclusion"]) for p in posts] == [("qa-review", "success"), ("qa-test-run", "action_required")]
    assert "wait for" in posts[1]["output"]["title"]


def test_panel_verdict_replaces_the_retarget_placeholder(monkeypatch):
    # A retarget brought only an e2e workflow change into scope (no new spec): the panel
    # passes, and qa-test-run must turn green instead of staying on the placeholder.
    api = review_api(check_runs=[PLACEHOLDER], files=[])
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.collect_review(review_event(body=marker("pass")), "o/r", "tok", "loft-bot", "qa-review")
    assert [(c["name"], c["conclusion"]) for c in decision["checks"]] == [
        ("qa-review", "success"), ("qa-test-run", "success")]
    gate.apply(decision, "o/r", "tok", "", "https://run")
    posts = [(a, p) for a, p in api.writes if a == "repos/o/r/check-runs"]
    assert [(p["name"], p["conclusion"]) for a, p in posts] == [("qa-review", "success"), ("qa-test-run", "success")]
    patches = [(a, p) for a, p in api.writes if a != "repos/o/r/check-runs"]
    assert not any(p.get("conclusion") == "action_required" for a, p in patches), "the placeholder must not be copied back"


def test_review_opens_the_test_run_check_waiting_when_the_pr_adds_specs(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", review_api(files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    test_run = decision["checks"][1]
    assert test_run["conclusion"] == "action_required"
    assert "1 new spec(s) wait for `/test-e2e <label-filter>`" in test_run["title"]
    assert "e2e/a.go:1 new" in test_run["summary"]
    assert "filter covering the listed specs" in test_run["summary"]


@pytest.mark.parametrize("declaration", ["It(tc.desc, func() {})", "Describe(tc.desc, func() {})"])
def test_review_computed_name_never_passes_as_no_specs(monkeypatch, declaration):
    files = [{"filename": "e2e/a.go", "patch": f"@@ -1,0 +1 @@\n+ {declaration}"}]
    monkeypatch.setattr(gate, "gh_api", review_api(files=files))
    check = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")["checks"][1]
    assert check["conclusion"] == "action_required"
    assert "e2e/a.go:1" in check["summary"]
    assert "/test-e2e <label-filter>" in check["summary"]


def test_review_opener_rechecks_for_a_result_before_posting(monkeypatch):
    api = review_api(files=NEW_SPEC)
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    completed = review_api(check_runs=[{"app": {"slug": "github-actions"}, "conclusion": "success", "external_id": "^main"}], files=NEW_SPEC)
    monkeypatch.setattr(gate, "gh_api", completed)
    gate.apply(decision, "o/r", "tok", "", "https://run")
    assert [payload["name"] for _, payload in completed.writes] == ["qa-review"]


@pytest.mark.parametrize("conclusion", ["success", "failure", "action_required"])
def test_review_opener_reconciles_result_posted_between_lookup_and_create(monkeypatch, conclusion):
    monkeypatch.setattr(gate, "gh_api", review_api(files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    writes = []
    result = {"app": {"slug": "github-actions"}, "id": 20, "status": "completed", "conclusion": conclusion,
              "details_url": "https://e2e", "output": {"title": "E2E result", "summary": "details"}}

    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": [result, {"app": {"slug": "github-actions"}, "id": 21, "status": "completed"}]
                    if "filter=all" in args[0] else []}
        if payload is not None:
            writes.append((args, payload))
            return {"id": 21}
        return {}

    monkeypatch.setattr(gate, "gh_api", api)
    gate.apply(decision, "o/r", "tok", "", "https://panel")
    args, payload = writes[-1]
    assert args == ["repos/o/r/check-runs/21", "-X", "PATCH"]
    assert payload == {"status": "completed", "conclusion": conclusion,
                       "details_url": "https://e2e",
                       "output": {"title": "E2E result", "summary": "details"}}


def test_a_verdict_for_another_base_than_the_pr_targets_is_ignored(monkeypatch):
    # The panel started on main, the PR was retargeted to release-1.0 meanwhile.
    api = review_api(files=NEW_SPEC)
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.collect_review(review_event(body=marker(verdict="pass", base="release-1.0")),
                                   "o/r", "tok", "loft-bot", "qa-review")
    assert decision == {"skip": "marker is for base release-1.0, PR targets main; the panel reviews the new base"}
    assert not api.writes


def test_review_leaves_an_existing_test_run_check_alone(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", review_api(check_runs=[{"app": {"slug": "github-actions"}, "conclusion": "success", "external_id": "^main"}], files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    assert "checks" not in decision and decision["check"]["name"] == "qa-review"


@pytest.mark.parametrize("legacy", [{}, {"external_id": "qa-review-gate:trees:ginkgo-report=success"}])
def test_panel_verdict_replaces_a_test_run_result_that_records_no_base(monkeypatch, legacy):
    # Written before the gate recorded the base: it may be for the diff before a retarget.
    old = {"app": {"slug": "github-actions"}, "id": 7, "status": "completed", "conclusion": "success", **legacy}
    monkeypatch.setattr(gate, "gh_api", review_api(check_runs=[old], files=NEW_SPEC))
    decision = gate.collect_review(review_event(body=marker("pass")), "o/r", "tok", "loft-bot", "qa-review")
    assert [(c["name"], c["conclusion"]) for c in decision["checks"]] == [
        ("qa-review", "success"), ("qa-test-run", "action_required")]


def test_review_diff_failure_opens_the_test_run_check_for_a_person(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", review_api(files=None))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    assert decision["checks"][1]["conclusion"] == "action_required"
    assert "cannot identify new specs" in decision["checks"][1]["title"]


def test_review_skip_makes_no_api_call(monkeypatch):
    def no_network(*args, **kwargs):
        raise AssertionError("a skipped review must not reach the API")
    monkeypatch.setattr(gate, "gh_api", no_network)
    assert "skip" in gate.collect_review(review_event(login="anvesh-loft"), "o/r", "tok", "loft-bot", "qa-review")


def test_needs_human_assigns_the_author_not_qa(monkeypatch):
    api = review_api(files=[])
    monkeypatch.setattr(gate, "gh_api", api)
    event = review_event(body=marker(verdict="needs_human", classes="b:1"))
    decision = gate.collect_review(event, "o/r", "tok", "loft-bot", "qa-review")
    assert gate.apply(decision, "o/r", "tok", "loft-sh/eng-qa", "https://run") == HEAD
    assert ("repos/o/r/issues/1/assignees", {"assignees": ["dev-x"]}) in api.writes
    assert not any(a.endswith("/requested_reviewers") for a, p in api.writes)


def test_review_from_a_human_is_ignored():
    assert "skip" in gate.decide_review(review_event(login="anvesh-loft"), "loft-bot", "qa-review")


def test_review_without_marker_is_ignored():
    assert "skip" in gate.decide_review(review_event(body="Panel review: 0 blocking"), "loft-bot", "qa-review")


def test_stale_marker_for_an_older_head_is_ignored():
    decision = gate.decide_review(review_event(head=OTHER), "loft-bot", "qa-review")
    assert "skip" in decision and "marker is for" in decision["skip"]


def test_override_by_qa_login_succeeds_with_reason():
    event = comment_event("/qa-review override the spec is covered by the nightly suite")
    decision = gate.decide_comment(event, {"sowmyav27"}, "qa-review")
    assert [(c["name"], c["conclusion"], c["head_sha"]) for c in decision["checks"]] == [
        ("qa-review", "success", None), ("qa-test-run", "success", None)]
    assert "overrode the panel verdict: the spec is covered" in decision["checks"][0]["summary"]
    assert decision["pr_number"] == 1 and decision["comment_at"] == "2026-11-18T10:00:00Z"


def test_override_by_a_login_outside_the_list_is_ignored():
    event = comment_event("/qa-review override trust me", login="someone-else")
    assert "skip" in gate.decide_comment(event, {"sowmyav27"}, "qa-review")


def test_override_by_a_team_member_counts():
    event = comment_event("/qa-review override trust me", login="lead-x")
    decision = gate.decide_comment(event, set(), "qa-review", member=lambda login: login == "lead-x")
    assert decision["checks"][0]["title"] == "QA review: overridden by @lead-x"


def test_team_member_reads_active_membership_and_skips_404(monkeypatch):
    calls = []

    def fake(args, token, payload=None):
        calls.append(args[0])
        if "eng-tech-leads" in args[0]:
            raise gate.GateError("gh api failed: HTTP 404")
        return {"state": "active"}
    monkeypatch.setattr(gate, "gh_api", fake)
    teams = ["loft-sh/eng-tech-leads", "loft-sh/eng-qa"]
    assert gate.team_member("sowmyav27", teams, "org-tok") is True
    assert calls == ["orgs/loft-sh/teams/eng-tech-leads/memberships/sowmyav27",
                     "orgs/loft-sh/teams/eng-qa/memberships/sowmyav27"]


def test_team_member_pending_or_no_token_is_not_a_member(monkeypatch, capsys):
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: {"state": "pending"})
    assert gate.team_member("x", ["loft-sh/eng-qa"], "org-tok") is False
    assert gate.team_member("x", ["loft-sh/eng-qa"], "") is False
    assert "no org-token" in capsys.readouterr().out


def test_override_reason_is_optional():
    decision = gate.decide_comment(comment_event("/qa-review override"), {"sowmyav27"}, "qa-review")
    assert "overrode the panel verdict: no reason given" in decision["checks"][0]["summary"]


def test_human_request_by_member_asks_the_team():
    decision = gate.decide_comment(comment_event("/qa-review human", login="dev-x"), set(), "qa-review")
    assert decision["check"]["conclusion"] == "action_required"
    assert decision["request_qa_review"] is True


def test_human_request_by_outsider_is_ignored():
    event = comment_event("/qa-review human", login="drive-by", association="NONE")
    assert "skip" in gate.decide_comment(event, set(), "qa-review")


def test_command_must_open_the_first_line():
    assert "skip" in gate.decide_comment(comment_event("please /qa-review override x"), {"sowmyav27"}, "qa-review")
    assert "skip" in gate.decide_comment(comment_event("/test-e2e pr"), {"sowmyav27"}, "qa-review")


def test_comment_on_an_issue_is_ignored():
    assert "skip" in gate.decide_comment(comment_event("/qa-review human", on_pr=False), set(), "qa-review")


def flake_fixer_event():
    pr = backport_pr(login="vcluster-qa-bot[bot]", ref="flake-fixer/43778070525-feature-db-connector")
    return backport_event(pr, sender="vcluster-qa-bot[bot]")


def test_flake_fixer_pr_gets_both_checks_green():
    decision = gate.decide_bot(flake_fixer_event(), BOTS, "qa-review")
    assert [c["conclusion"] for c in decision["checks"]] == ["success", "success"]
    assert "vcluster-qa-bot[bot] PR" in decision["checks"][0]["title"]


def test_flake_fixer_branch_by_a_person_is_not_trusted():
    pr = backport_pr(login="roehrijn", ref="flake-fixer/x")
    assert "skip" in gate.decide_bot(backport_event(pr, sender="roehrijn"), BOTS, "qa-review")


@pytest.mark.parametrize("bad", ["loft-bot", "loft-bot:", ":backport/"])
def test_parse_bots_rejects_a_half_entry(bad):
    with pytest.raises(gate.GateError):
        gate.parse_bots(bad)


BASE = "b" * 40


def human_pr_event(files, action="opened"):
    pr = {"number": 12, "user": {"login": "roehrijn"}, "head": {"sha": HEAD, "ref": "fix/thing"},
          "base": {"sha": BASE, "ref": "main"}, "html_url": "https://github.com/o/r/pull/12"}
    return {"action": action, "pull_request": pr, "sender": {"login": "roehrijn"}}, files


def files_api(files, seen=None):
    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": []}
        if seen is not None:
            seen.append(args[0])
        return {"files": [{"filename": f} for f in files]}
    return api


QA_PATHS = gate.parse_paths(gate.DEFAULT_QA_PATHS)


def test_a_pr_outside_the_qa_paths_passes_as_out_of_scope(monkeypatch):
    event, files = human_pr_event(["docs/README.md", "pkg/foo.go", ".github/workflows/unit.yaml"])
    monkeypatch.setattr(gate, "gh_api", files_api(files))
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    names = [(c["name"], c["conclusion"], c["head_sha"], c["external_id"]) for c in decision["checks"]]
    assert names == [("qa-review", "success", HEAD, "qa-review-gate:scope"),
                     ("qa-test-run", "success", HEAD, "qa-review-gate:scope")]
    assert decision["checks"][0]["title"] == f"QA review: out of scope, no QA-owned path (base main@{BASE[:7]})"
    assert decision["pr_number"] == 12 and decision["request_qa_review"] is False


@pytest.mark.parametrize("path", ["e2e/test_foo/foo.go", "e2e-next/setup/x.go",
                                  "staging/github.com/loft-sh/vcluster/e2e/bar.go",
                                  ".github/workflows/e2e-ginkgo.yaml"])
def test_a_pr_touching_a_qa_path_waits_for_the_panel_and_says_how(monkeypatch, path):
    event, files = human_pr_event(["pkg/foo.go", path])
    monkeypatch.setattr(gate, "gh_api", files_api(files))
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [(c["name"], c["conclusion"], c["head_sha"], c["external_id"]) for c in decision["checks"]] == [
        ("qa-review", "action_required", HEAD, "qa-review-gate:scope"),
        ("qa-test-run", "action_required", HEAD, "qa-review-gate:scope")]
    assert decision["checks"][0]["title"] == "QA review: waiting for the panel review, comment /vcluster-review"
    assert "`/vcluster-review`" in decision["checks"][0]["summary"] and "/qa-review override" in decision["checks"][0]["summary"]
    assert decision["request_qa_review"] is False


@pytest.mark.parametrize("path", ["e2e/vendor/example.go", "e2e-next/vendor/github.com/x/y.go",
                                  "staging/github.com/loft-sh/vcluster/e2e/vendor/z.go", "pkg/e2e/foo.go"])
def test_scope_matches_paths_like_the_dispatcher(monkeypatch, path):
    # The dispatcher ignores vendored files and keeps a star inside one segment, so the
    # panel never runs on these; the gate must pass them, or the PR gets no check at all.
    event, files = human_pr_event([path])
    monkeypatch.setattr(gate, "gh_api", files_api(files))
    assert "checks" in gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")


def test_qa_owned_agrees_with_the_dispatcher_matcher():
    patterns = QA_PATHS
    assert gate.qa_owned(["e2e/a.go", "e2e-next/b/c.go", "e2eX/d.go"], patterns) == \
        ["e2e/a.go", "e2e-next/b/c.go", "e2eX/d.go"]
    assert gate.qa_owned(["e2e", "docs/e2e/a.go", "e2e/vendor/a.go", "staging/github.com/loft-sh/vcluster/e2e"],
                         patterns) == []


def retarget_event(files, newest_external_id):
    event, files = human_pr_event(files, action="edited")
    event["changes"] = {"base": {"ref": {"from": "main"}, "sha": {"from": "9" * 40}}}
    event["pull_request"]["base"] = {"sha": BASE, "ref": "release-1.0"}
    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": [{"app": {"slug": "github-actions"}, "id": 5, "external_id": "x"}, {"app": {"slug": "github-actions"}, "id": 7, "external_id": newest_external_id}]}
        return {"files": [{"filename": f} for f in files]}
    return event, api


def test_a_retarget_into_scope_takes_the_out_of_scope_pass_back(monkeypatch):
    event, api = retarget_event(["e2e/a.go"], gate.SCOPE_EXTERNAL_ID)
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [(c["name"], c["conclusion"], c["head_sha"]) for c in decision["checks"]] == \
        [("qa-review", "action_required", HEAD), ("qa-test-run", "action_required", HEAD)]
    assert decision["checks"][0]["title"] == "QA review: 1 file(s) in scope after retarget to release-1.0, the panel decides"


def test_a_retarget_into_scope_before_any_check_writes_the_placeholder(monkeypatch):
    # The retarget job overtook the queued opened job: nothing to revoke yet, still a placeholder.
    event, _ = retarget_event(["e2e/a.go"], "")
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None:
                        {"check_runs": []} if "check-runs?" in args[0] else {"files": [{"filename": "e2e/a.go"}]})
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [c["conclusion"] for c in decision["checks"]] == ["action_required", "action_required"]


OWNS_BOTH = {"skip": "the panel's verdict, a request for a person or an override owns both checks"}


@pytest.mark.parametrize("newest", ["qa-review-gate:verdict^release-1.0", gate.OVERRIDE_EXTERNAL_ID,
                                    gate.HUMAN_EXTERNAL_ID, gate.BOT_EXTERNAL_ID])
def test_a_retarget_into_scope_leaves_a_result_for_the_new_base_alone(monkeypatch, newest):
    # A verdict for the new base, an override, a request for a person and a bot pass all stay.
    event, api = retarget_event(["e2e/a.go"], newest)
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review") == OWNS_BOTH


@pytest.mark.parametrize("newest", ["qa-review-gate:verdict^main", gate.OPENER_EXTERNAL_ID + "^main",
                                    "qa-review-gate:trees:ginkgo-report=success^main",
                                    # No recorded base (written before the gate recorded it): same head,
                                    # so the result may be for the old diff and needs a fresh decision.
                                    "qa-review-gate:verdict", gate.OPENER_EXTERNAL_ID,
                                    "qa-review-gate:trees:ginkgo-report=success"])
def test_a_retarget_into_scope_replaces_a_result_graded_against_the_old_base(monkeypatch, newest):
    event, api = retarget_event(["e2e/a.go"], newest)
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [c["conclusion"] for c in decision["checks"]] == ["action_required", "action_required"]
    assert decision["base_ref"] == "release-1.0"


def test_a_reopen_on_the_same_head_never_writes_over_a_request_for_a_person(monkeypatch):
    event, files = human_pr_event(["docs/a.md"], action="reopened")
    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": [{"app": {"slug": "github-actions"}, "id": 3, "status": "completed",
                                    "conclusion": "action_required", "external_id": gate.HUMAN_EXTERNAL_ID}]
                    if "check_name=qa-review&" in args[0] else []}
        return {"files": [{"filename": f} for f in files]}
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [c["name"] for c in decision["checks"]] == ["qa-test-run"]


def legacy(conclusion, title):
    # The gate before base tracking wrote manual decisions with no external id.
    return {"app": {"slug": "github-actions"}, "id": 3, "status": "completed", "conclusion": conclusion,
            "output": {"title": title, "summary": "s"}}


def test_a_reopen_on_the_same_head_keeps_a_request_for_a_person_written_without_an_external_id(monkeypatch):
    event, files = human_pr_event(["docs/a.md"], action="reopened")
    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": [legacy("action_required", "QA review: a QA engineer decides")]
                    if "check_name=qa-review&" in args[0] else []}
        return {"files": [{"filename": f} for f in files]}
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [c["name"] for c in decision["checks"]] == ["qa-test-run"]


def test_a_retarget_into_scope_keeps_overrides_written_without_an_external_id(monkeypatch):
    event, _ = retarget_event(["e2e/a.go"], "")
    def api(args, token, payload=None):
        if "check_name=qa-review&" in args[0]:
            return {"check_runs": [legacy("success", "QA review: overridden by @lead")]}
        if "check_name=qa-test-run&" in args[0]:
            return {"check_runs": [legacy("success", "QA test run: overridden by @lead")]}
        return {"files": [{"filename": "e2e/a.go"}]}
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review") == OWNS_BOTH


def test_a_retarget_into_scope_regrades_a_panel_verdict_written_without_an_external_id(monkeypatch):
    event, _ = retarget_event(["e2e/a.go"], "")
    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": [legacy("success", "QA review: the panel passed the PR")]}
        return {"files": [{"filename": "e2e/a.go"}]}
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [c["conclusion"] for c in decision["checks"]] == ["action_required", "action_required"]


def test_a_retarget_replaces_only_the_checks_the_scope_check_still_owns(monkeypatch):
    # The panel ran between the base change and this job: its verdict owns qa-review, its
    # opener owns qa-test-run; the opposite split (a verdict, a scope-owned test run) is the
    # one Piotr reproduced, so each check is decided on its own.
    event, _ = retarget_event(["e2e/a.go"], "")
    def api(args, token, payload=None):
        if "check_name=qa-review&" in args[0]:
            return {"check_runs": [{"app": {"slug": "github-actions"}, "id": 9, "external_id": "qa-review-gate:verdict^release-1.0"}]}
        if "check_name=qa-test-run&" in args[0]:
            return {"check_runs": [{"app": {"slug": "github-actions"}, "id": 8, "external_id": gate.SCOPE_EXTERNAL_ID, "conclusion": "success"}]}
        return {"files": [{"filename": "e2e/a.go"}]}
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [(c["name"], c["conclusion"]) for c in decision["checks"]] == [("qa-test-run", "action_required")]


def test_a_retarget_whose_diff_cannot_be_listed_withdraws_the_pass(monkeypatch):
    event, _ = retarget_event(["e2e/a.go"], gate.SCOPE_EXTERNAL_ID)
    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": [{"app": {"slug": "github-actions"}, "id": 7, "external_id": gate.SCOPE_EXTERNAL_ID, "conclusion": "success"}]}
        return {"files": [{"filename": f"f{i}.go"} for i in range(gate.COMPARE_FILE_CAP)]}
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [(c["name"], c["conclusion"]) for c in decision["checks"]] == \
        [("qa-review", "action_required"), ("qa-test-run", "action_required")]
    assert decision["checks"][0]["title"] == "QA review: scope unknown after retarget to release-1.0, the panel decides"


def test_a_retarget_out_of_scope_never_overwrites_a_panel_verdict(monkeypatch):
    event, api = retarget_event(["docs/a.md"], "qa-review-gate:verdict^release-1.0")
    monkeypatch.setattr(gate, "gh_api", api)
    assert "skip" in gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")


def test_a_retarget_that_stays_out_of_scope_passes_against_the_new_base(monkeypatch):
    event, api = retarget_event(["docs/a.md"], gate.SCOPE_EXTERNAL_ID)
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert decision["checks"][0]["conclusion"] == "success"
    assert decision["checks"][0]["title"] == f"QA review: out of scope, no QA-owned path (base release-1.0@{BASE[:7]})"


def test_an_edit_without_a_base_change_is_ignored(monkeypatch):
    event, files = human_pr_event(["docs/a.md"], action="edited")
    event["changes"] = {"title": {"from": "old"}}
    monkeypatch.setattr(gate, "gh_api", lambda *a, **k: pytest.fail("no API call expected"))
    assert gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review") == \
        {"skip": "pull_request edited: the base did not change"}


def test_scope_grades_the_event_head_not_the_pr_current_head(monkeypatch):
    # A stale event: the PR has moved on, but the compare is bound to the event's own SHAs.
    event, files = human_pr_event(["pkg/a.go"])
    seen = []
    monkeypatch.setattr(gate, "gh_api", files_api(files, seen))
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert seen == [f"repos/o/r/compare/{BASE}...{HEAD}"]
    assert all(c["head_sha"] == HEAD for c in decision["checks"])


MANY = [{"filename": f"pkg/f{i}.go"} for i in range(gate.COMPARE_FILE_CAP)]


def test_a_compare_at_the_cap_falls_back_to_the_paginated_pr_files(monkeypatch):
    # loft-enterprise#9650: 429 files, none under a QA path; the compare stops at 300.
    seen = []
    def api(args, token, payload=None):
        seen.append(args[0])
        if "/compare/" in args[0]:
            return {"files": MANY}
        if args[0] == "repos/o/r/pulls/12":
            return {"head": {"sha": HEAD}, "base": {"sha": BASE}, "changed_files": 401}
        if "/pulls/12/files" in args[0]:
            return [[{"filename": f"pkg/f{i}.go"} for i in range(100)] for _ in range(4)] + [[{"filename": "docs/x.md"}]]
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    event, _ = human_pr_event([])
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert [c["conclusion"] for c in decision["checks"]] == ["success", "success"]
    assert "repos/o/r/pulls/12/files?per_page=100" in seen
    assert seen.count("repos/o/r/pulls/12") == 2  # the SHAs are read again after paging


@pytest.mark.parametrize("changed, pages, moved", [
    (3001, 30, False),   # the PR files API stops at 3000: the list is cut
    (401, 4, False),     # fewer files than the PR says it has
    (401, 4, True),      # a commit landed while paging
])
def test_a_cut_or_overtaken_fallback_list_is_not_used(monkeypatch, changed, pages, moved):
    calls = {"pr": 0}
    def api(args, token, payload=None):
        if "/compare/" in args[0]:
            return {"files": MANY}
        if args[0] == "repos/o/r/pulls/12":
            calls["pr"] += 1
            head = "f" * 40 if moved and calls["pr"] > 1 else HEAD
            return {"head": {"sha": head}, "base": {"sha": BASE}, "changed_files": changed}
        if "/pulls/12/files" in args[0]:
            return [[{"filename": f"pkg/f{p}_{i}.go"} for i in range(100)] for p in range(pages)]
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    event, _ = human_pr_event([])
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert "skip" in decision


def test_a_compare_at_the_cap_on_a_pr_that_moved_on_is_left_to_a_person(monkeypatch):
    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": []}
        if "/compare/" in args[0]:
            return {"files": MANY}
        if args[0] == "repos/o/r/pulls/12":
            return {"head": {"sha": "f" * 40}, "base": {"sha": BASE}}
        pytest.fail(f"the PR files list must not be read for another head: {args[0]}")
    monkeypatch.setattr(gate, "gh_api", api)
    event, _ = human_pr_event([])
    decision = gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review")
    assert "skip" in decision and "may be cut" in decision["skip"]


def test_scope_ignores_other_pull_request_actions(monkeypatch):
    event, _ = human_pr_event(["pkg/a.go"], action="labeled")
    monkeypatch.setattr(gate, "gh_api", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no lookup")))
    assert gate.decide_scope(event, "o/r", "tok", QA_PATHS, "qa-review") == \
        {"skip": "pull_request labeled: nothing to decide"}


def test_main_bot_mode_falls_through_to_the_scope_check(tmp_path, monkeypatch, capsys):
    event, files = human_pr_event(["docs/README.md"])
    event_file = tmp_path / "event.json"
    event_file.write_text(json.dumps(event))
    for key, value in {"INPUT_MODE": "bot", "GITHUB_EVENT_PATH": str(event_file), "GITHUB_REPOSITORY": "o/r",
                       "INPUT_GITHUB_TOKEN": "tok"}.items():
        monkeypatch.setenv(key, value)
    writes = []
    def api(args, token, payload=None):
        if "/compare/" in args[0]:
            return {"files": [{"filename": f} for f in files]}
        if args[0] == "repos/o/r/pulls/12":
            return {"number": 12, "base": {"ref": "main", "sha": BASE}, "head": {"sha": HEAD}}
        if payload is not None:
            writes.append(payload)
            return {"id": 1}
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.main() == 0
    assert [w["name"] for w in writes] == ["qa-review", "qa-test-run"]
    assert "is not a trusted bot PR" in capsys.readouterr().out


def test_regrade_stays_on_the_head_this_job_queued_for(monkeypatch, capsys):
    event, _ = human_pr_event(["docs/README.md"])
    moved = {"number": 12, "base": {"ref": "release-1.0", "sha": "c" * 40}, "head": {"sha": "9" * 40}}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None:
                        moved if args[0] == "repos/o/r/pulls/12" else pytest.fail(f"no other call expected: {args[0]}"))
    assert gate.regrade_if_retargeted(event, "o/r", "tok", QA_PATHS, "qa-review", "qa-test-run", "", "u", "loft-bot") is None
    assert "its own event grades it" in capsys.readouterr().out


def test_a_scope_write_keeps_a_verdict_that_landed_during_it(monkeypatch, capsys):
    # The sweep runs outside the head's queue: between its read and its POST the panel
    # passed qa-review; the sweep's pass must show the verdict, not hide it.
    decision = {"checks": [{"name": "qa-review", "head_sha": HEAD, "conclusion": "success",
                            "external_id": gate.SCOPE_EXTERNAL_ID, "title": "QA review: out of scope", "summary": "s"}],
                "request_qa_review": False, "pr_number": 12}
    verdict = {"id": 30, "status": "completed", "conclusion": "failure", "external_id": "",
               "app": {"slug": "github-actions"},  # a run from another app is never copied
               "details_url": "https://panel", "output": {"title": "QA review: blocked", "summary": "why"}}
    reads, writes = {"n": 0}, []
    def api(args, token, payload=None):
        if payload is not None:
            writes.append((args, payload))
            return {"id": 40}
        if "check-runs?" in args[0]:
            reads["n"] += 1
            return {"check_runs": [{"app": {"slug": "github-actions"}, "id": 20, "status": "completed", "external_id": gate.SCOPE_EXTERNAL_ID}]
                    + ([verdict] if reads["n"] > 2 else [])}  # the verdict shows up after the pre-write read
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    gate.apply(decision, "o/r", "tok", "", "https://run")
    patches = [(a, p) for a, p in writes if a[0] == "repos/o/r/check-runs/40"]
    assert patches and patches[0][1]["conclusion"] == "failure"
    assert patches[0][1]["output"]["title"] == "QA review: blocked" and patches[0][1]["external_id"] == ""
    assert "a result landed during the scope write" in capsys.readouterr().out


def test_main_regrades_when_a_retarget_overtook_the_scope_write(tmp_path, monkeypatch, capsys):
    # The opened job graded docs-only against main; by the time it wrote, the PR targeted
    # release-1.0, where the same head also changes an e2e file.
    event, _ = human_pr_event(["docs/README.md"])
    event_file = tmp_path / "event.json"
    event_file.write_text(json.dumps(event))
    for key, value in {"INPUT_MODE": "bot", "GITHUB_EVENT_PATH": str(event_file), "GITHUB_REPOSITORY": "o/r",
                       "INPUT_GITHUB_TOKEN": "tok"}.items():
        monkeypatch.setenv(key, value)
    writes, pulls = [], iter([{"base": {"ref": "main"}}, {"number": 12, "base": {"ref": "release-1.0", "sha": "c" * 40},
                                                          "head": {"sha": HEAD}, "html_url": "u"}])
    def api(args, token, payload=None):
        if "/compare/" in args[0]:
            base = args[0].split("/compare/")[1].split("...")[0]
            return {"files": [{"filename": "docs/README.md"}] + ([{"filename": "e2e/x.go"}] if base == "c" * 40 else [])}
        if args[0] == "repos/o/r/pulls/12":
            return next(pulls)
        if "check-runs?" in args[0]:
            return {"check_runs": [{"app": {"slug": "github-actions"}, "id": 1, "external_id": gate.SCOPE_EXTERNAL_ID, "conclusion": "success"}]}
        if payload is not None:
            writes.append(payload)
            return {"id": 1}
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.main() == 0
    assert [(w["name"], w["conclusion"]) for w in writes] == [
        ("qa-review", "success"), ("qa-test-run", "success"),
        ("qa-review", "action_required"), ("qa-test-run", "action_required")]
    assert "(retargeted meanwhile)" in capsys.readouterr().out


def test_a_queued_opened_job_skips_a_pr_retargeted_meanwhile(monkeypatch):
    event, files = human_pr_event(["docs/README.md"])
    def api(args, token, payload=None):
        if args[0] == "repos/o/r/pulls/12":
            return {"base": {"ref": "release-1.0"}}
        pytest.fail(f"no compare or write expected, got {args[0]}")
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.decide_pull_request(event, "o/r", "tok", BOTS, QA_PATHS, "qa-review") == \
        {"skip": "PR now targets release-1.0, not main; the retarget event grades it"}


def test_main_sweep_mode(tmp_path, monkeypatch, capsys):
    event_file = tmp_path / "event.json"
    event_file.write_text("{}")
    for key, value in {"INPUT_MODE": "sweep", "GITHUB_EVENT_PATH": str(event_file), "GITHUB_REPOSITORY": "o/r",
                       "INPUT_GITHUB_TOKEN": "tok"}.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: [[]] if "pulls?" in args[0] else {})
    assert gate.main() == 0
    assert "sweep started 0 run(s)" in capsys.readouterr().out


def test_main_sweep_mode_with_a_pr_number_grades_that_pr(tmp_path, monkeypatch, capsys):
    event_file = tmp_path / "event.json"
    event_file.write_text("{}")
    for key, value in {"INPUT_MODE": "sweep", "INPUT_PR_NUMBER": "12", "INPUT_QUEUED_SHA": HEAD, "GITHUB_EVENT_PATH": str(event_file),
                       "GITHUB_REPOSITORY": "o/r", "INPUT_GITHUB_TOKEN": "tok"}.items():
        monkeypatch.setenv(key, value)
    pr = {"number": 12, "user": {"login": "roehrijn"}, "head": {"sha": HEAD, "ref": "a"}, "base": {"sha": BASE, "ref": "main"}}
    writes = []
    def api(args, token, payload=None):
        if args[0] == "repos/o/r/pulls/12":
            return pr
        if "check-runs?" in args[0]:
            return {"check_runs": []}
        if "/compare/" in args[0]:
            return {"files": [{"filename": "docs/a.md"}]}
        if payload is not None:
            writes.append(payload["name"])
            return {"id": 1}
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.main() == 0
    assert writes == ["qa-review", "qa-test-run"]
    assert "#12" in capsys.readouterr().out


def test_a_declined_bot_exemption_never_takes_the_scope_pass(monkeypatch):
    # A person's conflict fix on a docs-only backport: no QA path, still no pass.
    event = backport_event(sender="roehrijn", action="synchronize")
    monkeypatch.setattr(gate, "gh_api", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no lookup")))
    decision = gate.decide_pull_request(event, "o/r", "tok", BOTS, QA_PATHS, "qa-review")
    assert decision == {"skip": "only a head the bot pushed passes; the panel reviews this head", "final": True}


def test_a_bot_push_on_an_unpassed_head_never_takes_the_scope_pass(monkeypatch):
    event = backport_event(action="synchronize")
    monkeypatch.setattr(gate, "gh_api", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no lookup")))
    decision = gate.decide_pull_request(event, "o/r", "tok", BOTS, QA_PATHS, "qa-review",
                                        passed_before=lambda sha: False)
    assert decision["final"] and "had not passed" in decision["skip"]


def test_sweep_passes_only_open_prs_without_a_check_that_touch_no_qa_path(monkeypatch, capsys):
    prs = [
        {"number": 1, "user": {"login": "roehrijn"}, "head": {"sha": "1" * 40, "ref": "a"}, "base": {"sha": BASE}},
        {"number": 2, "user": {"login": "roehrijn"}, "head": {"sha": "2" * 40, "ref": "b"}, "base": {"sha": BASE}},
        {"number": 3, "user": {"login": "roehrijn"}, "head": {"sha": "3" * 40, "ref": "c"}, "base": {"sha": BASE}},
        {"number": 4, "user": {"login": "loft-bot"}, "head": {"sha": "4" * 40, "ref": "backport/x"}, "base": {"sha": BASE}},
    ]
    files = {"1" * 40: ["docs/a.md"], "2" * 40: ["pkg/b.go"], "3" * 40: ["e2e/c.go"], "4" * 40: ["docs/d.md"]}
    writes = []
    def api(args, token, payload=None):
        if args[0].startswith("repos/o/r/pulls?"):
            return [prs]
        if "check-runs?" in args[0]:
            if ("1" * 40) in args[0]:
                return {"check_runs": [{"id": 9, "status": "completed", "app": {"slug": "github-actions"}}]}
            if ("2" * 40) in args[0]:  # a check by another app does not satisfy the ruleset
                return {"check_runs": [{"id": 8, "status": "completed", "app": {"slug": "some-other-app"}}]}
            return {"check_runs": []}
        if "/compare/" in args[0]:
            head = args[0].split("...")[1]
            return {"files": [{"filename": f} for f in files[head]]}
        if payload is not None:
            writes.append(payload)
            return {"id": 1}
        return {}
    def api_with_pr(args, token, payload=None):
        if args[0].startswith("repos/o/r/pulls/") and args[0][len("repos/o/r/pulls/"):].isdigit():
            return next(p for p in prs if p["number"] == int(args[0].rsplit("/", 1)[1]))
        if "/dispatches" in args[0]:
            writes.append(("dispatch", args[0], payload))
            return {}
        return api(args, token, payload)
    monkeypatch.setattr(gate, "gh_api", api_with_pr)
    # The manual run lists and dispatches: one run per PR lacking a check, none for #1.
    assert gate.sweep("o/r", "tok", "qa-review", "qa-test-run",
                      "o/r/.github/workflows/qa-review-gate.yaml@refs/heads/main") == 3
    assert writes == [("dispatch", "repos/o/r/actions/workflows/qa-review-gate.yaml/dispatches",
                       {"ref": "refs/heads/main", "inputs": {"pr-number": str(n)}}) for n in (2, 3, 4)]
    assert "sweep started 3 run(s): #2, #3, #4" in capsys.readouterr().out
    # Each dispatched run grades its PR under that head's queue.
    writes.clear()
    assert gate.sweep_one("o/r", "tok", 2, "2" * 40, BOTS, QA_PATHS, "qa-review", "qa-test-run", "", "https://run", "loft-bot")
    assert [(w["name"], w["head_sha"]) for w in writes] == [("qa-review", "2" * 40), ("qa-test-run", "2" * 40)]
    assert gate.sweep_one("o/r", "tok", 3, "3" * 40, BOTS, QA_PATHS, "qa-review", "qa-test-run", "", "https://run", "loft-bot")
    assert [(w["name"], w["conclusion"]) for w in writes[2:]] == [("qa-review", "action_required"), ("qa-test-run", "action_required")]
    assert not gate.sweep_one("o/r", "tok", 4, "4" * 40, BOTS, QA_PATHS, "qa-review", "qa-test-run", "", "https://run", "loft-bot")
    assert not gate.sweep_one("o/r", "tok", 1, "1" * 40, BOTS, QA_PATHS, "qa-review", "qa-test-run", "", "https://run", "loft-bot")
    out = capsys.readouterr().out
    assert "#3 3333333 QA review: waiting for the panel review, comment /vcluster-review (qa-review, qa-test-run created)" in out
    assert "::warning::qa-review-gate: #4 4444444 still lacks qa-review, qa-test-run (a trusted bot PR on a later head" in out
    assert "#1 1111111 has both checks" in out


def test_sweep_run_skips_a_pr_that_moved_after_it_queued(monkeypatch, capsys):
    pr = {"number": 8, "user": {"login": "roehrijn"}, "head": {"sha": "b" * 40, "ref": "a"}, "base": {"sha": BASE, "ref": "main"}}
    calls = []
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: calls.append((args, payload)) or pr)
    assert not gate.sweep_one("o/r", "tok", 8, "a" * 40, BOTS, QA_PATHS, "qa-review", "qa-test-run", "", "https://run", "loft-bot")
    assert calls == [(["repos/o/r/pulls/8"], None)]
    assert "#8 is on bbbbbbb, this run queued for aaaaaaa" in capsys.readouterr().out


def test_sweep_grades_the_pr_as_it_is_now_and_regrades_after_a_retarget(monkeypatch, capsys):
    # The open-PR list captured base main (docs-only); the PR now targets release-1.0 where
    # the same head also changes e2e: no stale pass may land.
    listed = {"number": 6, "user": {"login": "roehrijn"}, "head": {"sha": "6" * 40, "ref": "a"},
              "base": {"sha": BASE, "ref": "main"}}
    now = {**listed, "base": {"sha": "c" * 40, "ref": "release-1.0"}, "html_url": "u"}
    writes = []
    def api(args, token, payload=None):
        if args[0].startswith("repos/o/r/pulls?"):
            return [[listed]]
        if args[0] == "repos/o/r/pulls/6":
            return now
        if "check-runs?" in args[0]:
            return {"check_runs": []}
        if "/compare/" in args[0]:
            base = args[0].split("/compare/")[1].split("...")[0]
            return {"files": [{"filename": "docs/a.md"}] + ([{"filename": "e2e/x.go"}] if base == "c" * 40 else [])}
        if payload is not None:
            writes.append(payload)
            return {"id": 1}
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.sweep_one("o/r", "tok", 6, "6" * 40, BOTS, QA_PATHS, "qa-review", "qa-test-run", "", "https://run", "loft-bot")
    assert [w["conclusion"] for w in writes] == ["action_required", "action_required"]  # in scope against the base it has now
    assert "#6 6666666 QA review: waiting for the panel review" in capsys.readouterr().out


def test_sweep_counts_the_missing_checks_on_the_queued_head(monkeypatch):
    # The listed head had qa-review only; the run queued for the new head, which has neither.
    listed = {"number": 7, "user": {"login": "roehrijn"}, "head": {"sha": "7" * 40, "ref": "a"},
              "base": {"sha": BASE, "ref": "main"}}
    now = {**listed, "head": {"sha": "8" * 40, "ref": "a"}, "html_url": "u"}
    writes = []
    def api(args, token, payload=None):
        if args[0].startswith("repos/o/r/pulls?"):
            return [[listed]]
        if args[0] == "repos/o/r/pulls/7":
            return now
        if "check-runs?" in args[0]:
            old_head_review = ("7" * 40) in args[0] and "check_name=qa-review" in args[0]
            return {"check_runs": [{"id": 1, "status": "completed", "app": {"slug": "github-actions"}}] if old_head_review else []}
        if "/compare/" in args[0]:
            return {"files": [{"filename": "docs/a.md"}]}
        if payload is not None:
            writes.append((payload["name"], payload["head_sha"]))
            return {"id": 1}
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.sweep_one("o/r", "tok", 7, "8" * 40, BOTS, QA_PATHS, "qa-review", "qa-test-run", "", "https://run", "loft-bot")
    assert writes == [("qa-review", "8" * 40), ("qa-test-run", "8" * 40)]


def test_sweep_retry_creates_only_the_missing_check(monkeypatch):
    # The first sweep wrote qa-review, then the qa-test-run POST failed.
    pr = {"number": 5, "user": {"login": "roehrijn"}, "head": {"sha": "5" * 40, "ref": "a"}, "base": {"sha": BASE}}
    writes = []
    def api(args, token, payload=None):
        if args[0] == "repos/o/r/pulls/5":
            return pr
        if "check-runs?" in args[0]:
            return {"check_runs": [{"id": 9, "status": "completed", "app": {"slug": "github-actions"}}]
                    if "check_name=qa-review" in args[0] else []}
        if "/compare/" in args[0]:
            return {"files": [{"filename": "docs/a.md"}]}
        if payload is not None:
            writes.append(payload)
            return {"id": 1}
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    assert gate.sweep_one("o/r", "tok", 5, "5" * 40, BOTS, QA_PATHS, "qa-review", "qa-test-run", "", "https://run", "loft-bot")
    assert [w["name"] for w in writes] == ["qa-test-run"]


def test_opener_reconciliation_prefers_an_override_over_a_newer_failure(monkeypatch):
    calls = []
    runs = {"check_runs": [
        {"app": {"slug": "github-actions"}, "id": 3, "status": "completed", "external_id": "qa-review-gate:override", "conclusion": "success",
         "details_url": "https://c", "output": {"title": "QA test run: overridden by @sowmyav27", "summary": "why"}},
        {"app": {"slug": "github-actions"}, "id": 20, "status": "completed", "conclusion": "failure", "output": {"title": "E2E failed", "summary": "d"}},
        {"app": {"slug": "github-actions"}, "id": 21, "status": "completed", "conclusion": "action_required", "external_id": gate.OPENER_EXTERNAL_ID},
    ]}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None:
                        calls.append((args, payload)) or (runs if "check-runs?" in args[0] else {}))
    gate.reconcile_opener("o/r", HEAD, "qa-test-run", None, "tok", "https://run")
    patches = [(a, p) for a, p in calls if p]
    assert patches[0][0] == ["repos/o/r/check-runs/21", "-X", "PATCH"]
    assert patches[0][1]["conclusion"] == "success"
    assert patches[0][1]["output"]["title"] == "QA test run: overridden by @sowmyav27"


def test_backport_by_the_bot_gets_both_checks_green():
    decision = gate.decide_bot(backport_event(), BOTS, "qa-review")
    names = [(c["name"], c["conclusion"], c["head_sha"]) for c in decision["checks"]]
    assert names == [("qa-review", "success", HEAD), ("qa-test-run", "success", HEAD)]
    assert decision["request_qa_review"] is False and decision["pr_number"] == 9444


@pytest.mark.parametrize("pr", [backport_pr(login="roehrijn"), backport_pr(ref="fix/thing")])
def test_backport_needs_the_bot_author_and_the_backport_branch(pr):
    assert "skip" in gate.decide_bot(backport_event(pr), BOTS, "qa-review")


@pytest.mark.parametrize("event", [backport_event(sender="roehrijn"),
                                   backport_event(action="synchronize", sender="roehrijn"),
                                   backport_event(action="reopened")])
def test_only_a_head_the_bot_pushed_gets_a_free_pass(event):
    decision = gate.decide_bot(event, BOTS, "qa-review")
    assert decision == {"skip": "only a head the bot pushed passes; the panel reviews this head", "final": True}


def test_the_bots_own_later_push_gets_a_free_pass_when_it_builds_on_a_passed_head():
    asked = []
    decision = gate.decide_bot(backport_event(action="synchronize"), BOTS, "qa-review",
                               passed_before=lambda sha: asked.append(sha) or True)
    assert [c["conclusion"] for c in decision["checks"]] == ["success", "success"]
    assert asked == ["b" * 40]


def test_a_bot_push_on_a_head_the_gate_did_not_pass_goes_to_the_panel():
    decision = gate.decide_bot(backport_event(action="synchronize"), BOTS, "qa-review",
                               passed_before=lambda sha: False)
    assert decision == {"skip": "the bot built on a head the gate had not passed; the panel reviews this head",
                        "final": True}


def test_a_tree_result_graded_against_another_base_is_not_combined(monkeypatch):
    runs = {"check_runs": [{"app": {"slug": "github-actions"}, "id": 1, "status": "completed",
                            "external_id": "qa-review-gate:trees:ginkgo-report=success^main"}]}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: runs)
    assert gate.tree_results("o/r", HEAD, "qa-test-run", "tok", "main") == {"ginkgo-report": "success"}
    assert gate.tree_results("o/r", HEAD, "qa-test-run", "tok", "release-1.0") == {}


def test_apply_records_the_base_on_a_verdict_and_its_opener_but_not_on_an_override(monkeypatch):
    api = review_api(files=NEW_SPEC)
    monkeypatch.setattr(gate, "gh_api", api)
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    gate.apply(decision, "o/r", "tok", "", "https://run")
    assert [p["external_id"] for _, p in api.writes] == ["qa-review-gate:verdict^main",
                                                          gate.OPENER_EXTERNAL_ID + "^main"]
    calls = []
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None:
                        calls.append((args, payload)) or ({"check_runs": []} if "check-runs?" in args[0] else {"id": 5}))
    override = gate.decide_comment(comment_event("/qa-review override flaky"), {"sowmyav27"}, "qa-review")
    for check in override["checks"]:
        check["head_sha"] = HEAD
    gate.apply(override, "o/r", "tok", "", "https://run")
    assert all(p["external_id"] == gate.OVERRIDE_EXTERNAL_ID for a, p in calls if p)


def test_a_fresh_verdict_replaces_a_test_result_graded_against_the_old_base(monkeypatch):
    old = {"app": {"slug": "github-actions"}, "id": 9, "status": "completed", "conclusion": "failure",
           "external_id": "qa-review-gate:trees:ginkgo-report=failure^release-1.0"}
    monkeypatch.setattr(gate, "gh_api", review_api(check_runs=[old], files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    assert decision["opener_name"] == "qa-test-run" and "reconcile" not in decision
    same = {**old, "external_id": "qa-review-gate:trees:ginkgo-report=failure^main"}
    monkeypatch.setattr(gate, "gh_api", review_api(check_runs=[same], files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    assert decision["reconcile"] == "qa-test-run"


def test_runs_from_another_app_never_count(monkeypatch):
    other = {"slug": "some-other-app"}
    runs = {"check_runs": [{"id": 3, "status": "completed", "app": other, "external_id": "qa-review-gate:override",
                            "conclusion": "success"}]}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: runs)
    assert gate.override_run("o/r", HEAD, "qa-test-run", "tok") is None
    runs["check_runs"] = [{"id": 3, "status": "completed", "app": other, "external_id": "qa-review-gate:bot",
                           "conclusion": "success"}]
    assert gate.bot_passed("o/r", HEAD, "qa-review", "tok") is False
    runs["check_runs"] = [{"id": 1, "status": "completed", "app": other,
                           "external_id": "qa-review-gate:trees:ginkgo-report=success"}]
    assert gate.tree_results("o/r", HEAD, "qa-test-run", "tok") == {}
    calls = []
    runs["check_runs"] = [
        {"id": 20, "status": "completed", "app": other, "conclusion": "failure", "output": {"title": "x", "summary": "y"}},
        {"id": 21, "status": "completed", "app": {"slug": "github-actions"}, "conclusion": "action_required",
         "external_id": gate.OPENER_EXTERNAL_ID}]
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: calls.append((args, payload)) or runs)
    gate.reconcile_opener("o/r", HEAD, "qa-test-run", None, "tok", "https://run")
    assert not [p for a, p in calls if p]


def test_bot_passed_reads_this_gates_own_bot_check(monkeypatch):
    runs = {"check_runs": [{"app": {"slug": "github-actions"}, "external_id": "qa-review-gate:bot", "conclusion": "success"}]}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: runs)
    assert gate.bot_passed("o/r", "a" * 40, "qa-review", "tok") is True
    runs["check_runs"] = [{"app": {"slug": "github-actions"}, "external_id": None, "conclusion": "success"},
                          {"app": {"slug": "github-actions"}, "external_id": "qa-review-gate:bot", "conclusion": "failure"}]
    assert gate.bot_passed("o/r", "a" * 40, "qa-review", "tok") is False
    runs["check_runs"] = []
    assert gate.bot_passed("o/r", "a" * 40, "qa-review", "tok") is False


def test_panel_verdict_on_a_backport_counts():
    event = review_event(body=marker("block"))
    event["pull_request"] = backport_pr()
    assert gate.decide_review(event, "loft-bot", "qa-review")["check"]["conclusion"] == "failure"


def test_run_target_reads_the_tested_commit_from_a_dispatch_run_name():
    sha = "c" * 40
    run = {"event": "workflow_dispatch", "head_sha": "d" * 40,
           "display_title": f"E2E for PR #77 (platform && pr) at {sha}"}
    assert gate.run_target(run, "o/r", "tok") == (sha, 77)


def test_run_target_falls_back_to_the_run_head_and_its_pull_request(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: [{"number": 8, "state": "open"}])
    assert gate.run_target({"event": "workflow_dispatch", "head_sha": HEAD, "display_title": "E2E"},
                           "o/r", "tok") == (HEAD, 8)
    assert gate.run_target({"event": "pull_request", "pull_requests": [{"number": 5}], "head_sha": HEAD,
                            "display_title": f"E2E for PR #77 at {'c' * 40}"}, "o/r", "tok") == (HEAD, 5)


def test_the_import_fix_waits_for_the_opened_head_to_carry_its_pass(monkeypatch):
    seen = {"polls": 0}
    def api(args, token, payload=None):
        seen["polls"] += 1
        runs = [{"app": {"slug": "github-actions"}, "external_id": "qa-review-gate:bot", "conclusion": "success"}] if seen["polls"] >= 3 else []
        return {"check_runs": runs}
    monkeypatch.setattr(gate, "gh_api", api)
    naps = []
    assert gate.wait_for_bot_pass("o/r", "b" * 40, "qa-review", "tok", attempts=5, delay=7, sleep=naps.append)
    assert seen["polls"] == 3 and naps == [7, 7]


def test_the_import_fix_gives_up_when_the_opened_head_never_passes(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: {"check_runs": []})
    naps = []
    assert not gate.wait_for_bot_pass("o/r", "b" * 40, "qa-review", "tok", attempts=3, delay=1, sleep=naps.append)
    assert naps == [1, 1]


def test_a_rerun_puts_the_override_back_on_top_after_a_failed_repair(monkeypatch):
    # CI published 44 after the override 3; the repair PATCH failed; the gate reran.
    calls = []
    runs = {"check_runs": [
        {"app": {"slug": "github-actions"}, "id": 3, "external_id": "qa-review-gate:override", "conclusion": "success", "details_url": "https://c",
         "output": {"title": "QA test run: overridden by @sowmyav27", "summary": "why"}},
        {"app": {"slug": "github-actions"}, "id": 44, "conclusion": "failure", "output": {"title": "QA test run: 1 new spec(s) did not run or pass"}},
    ]}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None:
                        calls.append((args, payload)) or (runs if "check-runs?" in args[0] else {}))
    late = {"check": {"name": "qa-test-run", "head_sha": HEAD, "conclusion": "failure",
                      "title": "QA test run: 1 new spec(s) did not run or pass", "summary": "s"},
            "pr_number": 9, "request_qa_review": False}
    gate.apply(late, "o/r", "tok", "", "https://run")
    writes = [(a, p) for a, p in calls if p]
    assert writes == [(["repos/o/r/check-runs/44", "-X", "PATCH"],
                       {"status": "completed", "conclusion": "success", "details_url": "https://c",
                        "output": {"title": "QA test run: overridden by @sowmyav27", "summary": "why"}})]


def test_an_override_that_is_already_newest_needs_no_repair(monkeypatch):
    calls = []
    runs = {"check_runs": [{"app": {"slug": "github-actions"}, "id": 44, "conclusion": "failure"},
                           {"app": {"slug": "github-actions"}, "id": 45, "external_id": "qa-review-gate:override", "conclusion": "success"}]}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None:
                        calls.append((args, payload)) or (runs if "check-runs?" in args[0] else {}))
    late = {"check": {"name": "qa-test-run", "head_sha": HEAD, "conclusion": "failure", "title": "t", "summary": "s"},
            "pr_number": 9, "request_qa_review": False}
    gate.apply(late, "o/r", "tok", "", "https://run")
    assert not [p for a, p in calls if p]


def test_an_override_landing_during_the_write_still_wins(monkeypatch):
    calls = []
    state = {"reads": 0}
    override = {"app": {"slug": "github-actions"}, "id": 3, "external_id": "qa-review-gate:override", "conclusion": "success",
                "details_url": "https://comment",
                "output": {"title": "QA test run: overridden by @sowmyav27", "summary": "why"}}
    def api(args, token, payload=None):
        calls.append((args, payload))
        if "check-runs?" in args[0]:
            state["reads"] += 1
            return {"check_runs": [override, {"app": {"slug": "github-actions"}, "id": 44, "conclusion": "failure"}] if state["reads"] > 1 else []}
        return {"id": 44}
    monkeypatch.setattr(gate, "gh_api", api)
    late = {"check": {"name": "qa-test-run", "head_sha": HEAD, "conclusion": "failure",
                      "title": "QA test run: 1 new spec(s) did not run or pass", "summary": "s"},
            "pr_number": 9, "request_qa_review": False}
    gate.apply(late, "o/r", "tok", "", "https://run")
    writes = [(a, p) for a, p in calls if p]
    assert writes[0][0] == ["repos/o/r/check-runs", "-X", "POST"]
    assert writes[-1][0] == ["repos/o/r/check-runs/44", "-X", "PATCH"]
    assert writes[-1][1]["conclusion"] == "success"
    assert writes[-1][1]["output"]["title"] == "QA test run: overridden by @sowmyav27"


def test_a_late_result_does_not_undo_an_override(monkeypatch):
    calls = []
    override = {"check_runs": [{"app": {"slug": "github-actions"}, "id": 3, "external_id": "qa-review-gate:override", "conclusion": "success"}]}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None:
                        calls.append((args, payload)) or (override if "check-runs?" in args[0] else {}))
    late = {"check": {"name": "qa-test-run", "head_sha": HEAD, "conclusion": "failure",
                      "title": "QA test run: 1 new spec(s) did not run or pass", "summary": "s"},
            "pr_number": 9, "request_qa_review": False}
    assert gate.apply(late, "o/r", "tok", "", "https://run") == HEAD
    assert not [p for a, p in calls if p]


def test_an_override_writes_its_mark_and_still_posts_over_an_older_override(monkeypatch):
    calls = []
    older = {"check_runs": [{"app": {"slug": "github-actions"}, "id": 3, "external_id": "qa-review-gate:override", "conclusion": "success"}]}
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None:
                        calls.append((args, payload)) or (older if "check-runs?" in args[0] else {}))
    decision = gate.decide_comment(comment_event("/qa-review override flaky env"), {"sowmyav27"}, "qa-review")
    for check in decision["checks"]:
        check["head_sha"] = HEAD
    gate.apply(decision, "o/r", "tok", "", "https://run")
    posted = [p for a, p in calls if p]
    assert [p["name"] for p in posted] == ["qa-review", "qa-test-run"]
    assert all(p["external_id"] == "qa-review-gate:override" for p in posted)


def test_run_pr_number_prefers_the_event_then_the_head_commit():
    assert gate.run_pr_number({"pull_requests": [{"number": 5}]}, "o/r", "tok") == 5
    calls = []
    pulls = [{"number": 7, "state": "closed"}, {"number": 8, "state": "open"}]
    gate.gh_api, saved = (lambda args, token, payload=None: calls.append(args) or pulls), gate.gh_api
    try:
        assert gate.run_pr_number({"pull_requests": [], "head_sha": HEAD}, "o/r", "tok") == 8
        assert gate.run_pr_number({"pull_requests": []}, "o/r", "tok") is None
    finally:
        gate.gh_api = saved
    assert calls == [[f"repos/o/r/commits/{HEAD}/pulls"]]


def test_pr_diff_compares_the_base_with_the_run_head(monkeypatch):
    calls = []
    files = [{"filename": "e2e/a.go", "patch": '@@ -40,0 +41 @@\n+\tIt("new", func() {'},
             {"filename": "e2e/big.go", "additions": 0}]
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: calls.append(args) or {"files": files})
    assert gate.added_specs(gate.pr_diff("o/r", "main", HEAD, "tok")) == [
        {"path": "e2e/a.go", "line": 41, "text": "new"}]
    assert calls == [[f"repos/o/r/compare/main...{HEAD}"]]


def test_pr_diff_refuses_a_compare_the_api_may_have_cut(monkeypatch):
    files = [{"filename": f"e2e/{i}.go"} for i in range(300)]
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: {"files": files})
    with pytest.raises(gate.GateError):
        gate.pr_diff("o/r", "main", HEAD, "tok")


def ci_api(head=HEAD, files=None, artifacts=("ginkgo-report",), check_runs=()):
    def fake(args, token, payload=None):
        if "/compare/" in args[0]:
            if files is None:
                raise gate.GateError("gh api compare failed: 500")
            return {"files": files}
        if args[0].endswith("/artifacts"):
            return {"artifacts": [{"name": a, "id": n} for n, a in enumerate(artifacts)]}
        if "/check-runs?" in args[0]:
            return {"check_runs": list(check_runs)}
        return {"head": {"sha": head}, "base": {"ref": "main"}}
    return fake


def ci_run(number=9):
    return {"app": {"slug": "github-actions"}, "id": 7, "pull_requests": [{"number": number}], "head_sha": HEAD, "conclusion": "success"}


def test_ci_diff_failure_asks_a_person_instead_of_failing_the_job(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", ci_api())
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok")
    assert decision["check"]["name"] == "qa-test-run"
    assert decision["check"]["conclusion"] == "action_required"
    assert decision["base_ref"] == "main"  # a retarget can replace this result too
    assert decision["check"]["head_sha"] == HEAD and decision["pr_number"] == 9
    assert "/test-e2e" in decision["check"]["summary"]


def test_a_pr_run_is_credited_only_for_the_base_it_merged_with(monkeypatch):
    files = [{"filename": "e2e/a_test.go", "patch": '@@ -1,0 +1 @@\n+\tIt("x", func() {'}]
    monkeypatch.setattr(gate, "gh_api", ci_api(files=files))
    monkeypatch.setattr(gate, "download_report", lambda repo, artifact, dest, token: None)
    run = {**ci_run(), "event": "pull_request", "display_title": f"E2E for PR #9 at {HEAD} onto release-1.0"}
    decision = gate.collect_ci({"workflow_run": run}, "o/r", "tok")
    assert decision == {"skip": "the e2e run tested the head onto release-1.0, the PR now targets main; a new run grades it"}
    run["display_title"] = "E2E Ginkgo test suites"
    decision = gate.collect_ci({"workflow_run": run}, "o/r", "tok")
    assert "skip" in decision and "names no base" in decision["skip"]
    run["display_title"] = f"E2E for PR #9 at {HEAD} onto main"
    assert "skip" not in gate.collect_ci({"workflow_run": run}, "o/r", "tok")
    dispatch = {**ci_run(), "event": "workflow_dispatch", "display_title": f"E2E for PR #9 (x) at {HEAD}"}
    assert "skip" not in gate.collect_ci({"workflow_run": dispatch}, "o/r", "tok")  # the head alone, any base


def test_ci_run_for_an_older_head_is_superseded(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", ci_api(head=OTHER))
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok")
    assert decision == {"skip": f"e2e run is for {HEAD[:7]}, PR head is {OTHER[:7]}; superseded"}


def test_ci_cancelled_run_without_a_report_is_skipped(monkeypatch):
    def no_network(*args, **kwargs):
        raise AssertionError("a cancelled run must not reach the API")
    monkeypatch.setattr(gate, "gh_api", no_network)
    monkeypatch.setattr(gate, "gh", no_network)
    run = {**ci_run(), "conclusion": "cancelled"}
    assert gate.collect_ci({"workflow_run": run}, "o/r", "tok") == {
        "skip": "e2e run ended cancelled, nothing to compare"}


def test_ci_missing_report_asks_a_person(monkeypatch):
    files = [{"filename": "e2e/a.go", "patch": '@@ -1,0 +1 @@\n+\tIt("new", func() {'}]
    monkeypatch.setattr(gate, "gh_api", ci_api(files=files, artifacts=()))
    monkeypatch.setattr(gate, "download_report", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no download without an artifact")))
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok")
    assert decision["check"]["conclusion"] == "action_required"
    assert "no ginkgo-report for 1 new spec(s)" in decision["check"]["title"]
    assert "uploaded no report" in decision["check"]["summary"]
    assert "`/test-e2e <label-filter>`" in decision["check"]["summary"]


def test_ci_unreadable_report_asks_a_person(monkeypatch):
    files = [{"filename": "e2e/a.go", "patch": '@@ -1,0 +1 @@\n+\tIt("new", func() {'}]
    monkeypatch.setattr(gate, "gh_api", ci_api(files=files))

    def broken(repo, artifact, dest, token):
        raise gate.GateError("artifact download failed: zip is corrupt")
    monkeypatch.setattr(gate, "download_report", broken)
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok")
    assert decision["check"]["conclusion"] == "action_required"
    assert "ginkgo-report could not be read" in decision["check"]["title"]
    assert "zip is corrupt" in decision["check"]["summary"]


FLOWS = "E2E flows"


def history(monkeypatch, runs, artifacts, reports, lines=2, by_branch=(), workflows=frozenset({"E2E", FLOWS})):
    """collect_ci over `runs` beside the finishing run 7; artifacts {run id: [artifact]},
    reports {artifact id: [(line, state, attempts)] or a whole report}."""
    patch = "@@ -1,0 +1,%d @@" % lines + "".join(f'\n+\tIt("s{n}", func() {{' for n in range(1, lines + 1))
    base = ci_api(files=[{"filename": "e2e/a.go", "patch": patch}])

    def api(args, token, payload=None):
        if "/actions/workflows?" in args[0]:
            assert args[1:] == ["--paginate", "--slurp"]  # a repo can have more than 100 workflows
            return [{"workflows": [{"id": 70, "name": "E2E"}, {"id": 60, "name": "E2E label check"}]},
                    {"workflows": [{"id": 50, "name": FLOWS}]}]
        if "/actions/runs?" in args[0]:
            return {"workflow_runs": list(by_branch if "branch=" in args[0] else runs)}
        if args[0].endswith("/artifacts"):
            return {"artifacts": artifacts.get(int(args[0].split("/")[-2]), [])}
        return base(args, token, payload)

    def download(repo, artifact, dest, token):
        os.makedirs(dest)
        report = reports[artifact["id"]]
        if isinstance(report, list) and report and isinstance(report[0], tuple):
            report = [{"SpecReports": [{"LeafNodeType": "It", "State": state, "NumAttempts": attempts,
                                        "StartTime": (when or [""])[0],
                                        "LeafNodeLocation": {"FileName": "/w/e2e/a.go", "LineNumber": line}}
                                       for line, state, attempts, *when in report]}]
        pathlib.Path(dest, "report.json").write_text(json.dumps(report))
    monkeypatch.setattr(gate, "gh_api", api)
    monkeypatch.setattr(gate, "download_report", download)
    run = {**ci_run(), "name": "E2E", "workflow_id": 70, "event": "workflow_dispatch", "display_title": "E2E"}
    return gate.collect_ci({"workflow_run": run}, "o/r", "tok", workflows=workflows)["check"]


def older(**fields):
    return {"id": 5, "name": FLOWS, "workflow_id": 50, "event": "workflow_dispatch", "conclusion": "success",
            "head_sha": HEAD, "display_title": FLOWS, **fields}


def art(id, name="ginkgo-report", at="2026-01-01T00:00:00Z", **fields):
    return {"id": id, "name": name, "created_at": at, **fields}


def test_ci_two_label_filters_each_pass_their_spec(monkeypatch):
    """Ginkgo reports a spec the filter left out as skipped with no attempt; that must not
    replace the pass of the run that did select it."""
    check = history(monkeypatch, [older()],
                    {5: [art(1, "ginkgo-report.flow-a")], 7: [art(2, at="2026-01-02T00:00:00Z")]},
                    {1: [(1, "passed", 1), (2, "skipped", 0)], 2: [(1, "skipped", 0), (2, "passed", 1)]})
    assert check["conclusion"] == "success", check["summary"]


def test_ci_an_older_producer_artifact_name_is_not_read(monkeypatch):
    """`ginkgo-report-<flow>` comes from a workflow that says nothing about what it tested
    (a PR branch with the older flows workflow, on a released image): only `.` names count."""
    check = history(monkeypatch, [older()],
                    {5: [art(1, "ginkgo-report-flow-a")], 7: [art(2, at="2026-01-02T00:00:00Z")]},
                    {1: [(1, "passed", 1)], 2: [(2, "passed", 1)]})
    assert check["conclusion"] == "failure" and "did not run: e2e/a.go:1" in check["summary"]


def test_ci_a_spec_no_run_attempted_fails_as_skipped(monkeypatch):
    check = history(monkeypatch, [], {7: [art(2)]}, {2: [(1, "passed", 1), (2, "skipped", 0)]})
    assert check["conclusion"] == "failure" and "e2e/a.go:2 s2 (skipped)" in check["summary"]


def test_ci_a_rerun_of_one_run_id_is_ordered_by_upload_time(monkeypatch):
    """A re-run keeps the run id and adds a second artifact of the same name: the newer attempt
    wins, whatever the listing order."""
    artifacts = {7: [art(2, at="2026-01-02T00:00:00Z"), art(1, at="2026-01-01T00:00:00Z")]}
    check = history(monkeypatch, [], artifacts, {1: [(1, "passed", 1)], 2: [(1, "failed", 1)]}, lines=1)
    assert check["conclusion"] == "failure"
    check = history(monkeypatch, [], artifacts, {1: [(1, "failed", 1)], 2: [(1, "passed", 1)]}, lines=1)
    assert check["conclusion"] == "success"


def test_ci_the_attempt_that_started_last_counts_not_the_last_upload(monkeypatch):
    """Run 5 started its spec after run 7's attempt but uploaded first (#9481: an attempt 2 of an
    older run id beside a newer run). Ginkgo stamps nanoseconds and the runner's offset."""
    artifacts = {5: [art(1, at="2026-01-01T11:00:00Z")], 7: [art(2, at="2026-01-01T12:00:00Z")]}
    late, early = "2026-01-01T11:43:16.123456789+01:00", "2026-01-01T10:40:18.5Z"
    check = history(monkeypatch, [older()], artifacts,
                    {1: [(1, "failed", 1, late)], 2: [(1, "passed", 1, early)]}, lines=1)
    assert check["conclusion"] == "failure"
    check = history(monkeypatch, [older()], artifacts,
                    {1: [(1, "passed", 1, late)], 2: [(1, "failed", 1, early)]}, lines=1)
    assert check["conclusion"] == "success"


def test_ci_a_dry_run_report_passes_nothing(monkeypatch):
    dry = [{"SuiteConfig": {"DryRun": True}, "SpecReports": [
        {"LeafNodeType": "It", "State": "passed", "NumAttempts": 1,
         "LeafNodeLocation": {"FileName": "/w/e2e/a.go", "LineNumber": 1}}]}]
    check = history(monkeypatch, [], {7: [art(2)]}, {2: dry}, lines=1)
    assert check["conclusion"] == "failure" and "did not run" in check["summary"]


def test_ci_reads_only_runs_of_the_listed_workflows_for_this_head(monkeypatch):
    passed = [(1, "passed", 1)]
    for stranger in (older(workflow_id=60), older(event="schedule"), older(conclusion="cancelled"),
                     older(display_title=f"E2E for PR #9 (x) at {OTHER}"),
                     older(display_title=f"E2E for PR #8 (x) at {HEAD}")):
        check = history(monkeypatch, [stranger], {5: [art(1)], 7: [art(2)]}, {1: passed, 2: []}, lines=1)
        assert check["conclusion"] == "failure", stranger


def test_ci_matches_runs_by_workflow_id_not_by_run_name(monkeypatch):
    """A run's `name` is its run-name (`E2E for PR #9 (<label>) at <sha>`), different for every
    dispatch of one workflow (#9481). With no list, only the finishing run's workflow counts."""
    title = f"E2E for PR #9 (auto-nodes) at {HEAD}"
    same = older(workflow_id=70, name=title, display_title=title)
    artifacts = {5: [art(1)], 7: [art(2, at="2026-01-02T00:00:00Z")]}
    reports = {1: [(1, "passed", 1), (2, "skipped", 0)], 2: [(1, "skipped", 0), (2, "passed", 1)]}
    for workflows in (frozenset({"E2E", FLOWS}), frozenset()):
        assert history(monkeypatch, [same], artifacts, reports, workflows=workflows)["conclusion"] == "success"
    assert history(monkeypatch, [older()], artifacts, reports, workflows=frozenset())["conclusion"] == "failure"


def test_ci_reads_an_earlier_fork_dispatch_run_from_the_base_branch(monkeypatch):
    """A fork PR's /test-e2e run has the base commit as head_sha; its title names the PR and commit."""
    fork = older(head_sha=OTHER, display_title=f"E2E for PR #9 (x) at {HEAD}")
    check = history(monkeypatch, [], {5: [art(1)], 7: [art(2, at="2026-01-02T00:00:00Z")]},
                    {1: [(1, "passed", 1)], 2: [(1, "skipped", 0)]}, lines=1, by_branch=[fork])
    assert check["conclusion"] == "success", check["summary"]


def test_ci_an_expired_report_is_left_out(monkeypatch):
    def no_expired(repo, artifact, dest, token):
        assert artifact["id"] != 1, "an expired artifact has no zip"
        os.makedirs(dest)
        pathlib.Path(dest, "report.json").write_text(json.dumps([{"SpecReports": [
            {"LeafNodeType": "It", "State": "passed", "LeafNodeLocation": {"FileName": "/w/e2e/a.go", "LineNumber": 1}}]}]))
    artifacts = {5: [art(1, expired=True)], 7: [art(2)]}
    history(monkeypatch, [older()], artifacts, {2: []}, lines=1)
    monkeypatch.setattr(gate, "download_report", no_expired)
    run = {**ci_run(), "name": "E2E", "workflow_id": 70, "event": "workflow_dispatch", "display_title": "E2E"}
    check = gate.collect_ci({"workflow_run": run}, "o/r", "tok", workflows={"E2E", FLOWS})["check"]
    assert check["conclusion"] == "success"


PRO_TREES = {"ginkgo-report": "", "oss-ginkgo-report": "staging/github.com/loft-sh/vcluster/"}
OSS = "staging/github.com/loft-sh/vcluster/e2e/oss_test.go"


def test_parse_trees_default_and_pro():
    assert gate.parse_trees("") == {"ginkgo-report": ""}
    assert gate.parse_trees("ginkgo-report=,oss-ginkgo-report=staging/github.com/loft-sh/vcluster/") == PRO_TREES
    with pytest.raises(gate.GateError):
        gate.parse_trees("ginkgo-report")


def test_spec_tree_takes_the_longest_prefix():
    assert gate.spec_tree({"path": OSS}, PRO_TREES) == "oss-ginkgo-report"
    assert gate.spec_tree({"path": "e2e/pro_test.go"}, PRO_TREES) == "ginkgo-report"


def two_tree_specs():
    return [spec(10, "pro"), {"path": OSS, "line": 5, "text": "oss"}]


def test_ci_one_tree_reported_waits_for_the_other():
    states = gate.report_specs([{"SpecReports": [leaf(10, "passed")]}])
    decision = gate.decide_ci(run(), 1, two_tree_specs(), states, trees=PRO_TREES,
                              reported=["ginkgo-report"], known={})
    assert decision["check"]["conclusion"] == "action_required"
    assert "waiting for oss-ginkgo-report (1 new spec(s))" in decision["check"]["title"]
    assert decision["check"]["external_id"] == "qa-review-gate:trees:ginkgo-report=success"


def test_ci_second_tree_completes_the_gate_from_the_recorded_result():
    states = gate.report_specs([{"SpecReports": [leaf(5, "passed", file=RUNNER + OSS)]}])
    decision = gate.decide_ci(run(), 1, two_tree_specs(), states, trees=PRO_TREES,
                              reported=["oss-ginkgo-report"], known={"ginkgo-report": "success"})
    assert decision["check"]["conclusion"] == "success"
    assert "all 2 new spec(s) ran and passed" in decision["check"]["title"]
    assert decision["check"]["external_id"] == "qa-review-gate:trees:ginkgo-report=success;oss-ginkgo-report=success"


def test_ci_a_failed_tree_fails_the_gate_once_both_reported():
    states = gate.report_specs([{"SpecReports": [leaf(5, "skipped", file=RUNNER + OSS)]}])
    decision = gate.decide_ci(run(), 1, two_tree_specs(), states, trees=PRO_TREES,
                              reported=["oss-ginkgo-report"], known={"ginkgo-report": "success"})
    assert decision["check"]["conclusion"] == "failure"
    assert "1 new spec(s) did not run or pass" in decision["check"]["title"]
    assert f"{OSS}:5 oss (skipped)" in decision["check"]["summary"]


def test_ci_failure_recorded_by_an_earlier_run_names_the_tree():
    states = gate.report_specs([{"SpecReports": [leaf(10, "passed")]}])
    decision = gate.decide_ci(run(), 1, two_tree_specs(), states, trees=PRO_TREES,
                              reported=["ginkgo-report"], known={"oss-ginkgo-report": "failure"})
    assert decision["check"]["conclusion"] == "failure"
    assert decision["check"]["title"] == "QA test run: new spec(s) for oss-ginkgo-report did not run or pass in an earlier run"


def test_collect_ci_reads_the_other_tree_from_the_newest_tagged_check_run(monkeypatch):
    files = [{"filename": OSS, "patch": '@@ -4,0 +5 @@\n+\tIt("oss", func() {'},
             {"filename": "e2e/pro_test.go", "patch": '@@ -9,0 +10 @@\n+\tIt("pro", func() {'}]
    runs = [{"app": {"slug": "github-actions"}, "id": 1, "external_id": "qa-review-gate:trees:ginkgo-report=success^main"},
            {"app": {"slug": "github-actions"}, "id": 2, "external_id": gate.OPENER_EXTERNAL_ID + "^main"}]
    monkeypatch.setattr(gate, "gh_api", ci_api(files=files, artifacts=("oss-ginkgo-report",), check_runs=runs))
    report = [{"SpecReports": [leaf(5, "passed", file=RUNNER + OSS)]}]

    def download(repo, artifact, dest, token):
        os.makedirs(dest, exist_ok=True)
        pathlib.Path(dest, "report.json").write_text(json.dumps(report))
    monkeypatch.setattr(gate, "download_report", download)
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok", trees=PRO_TREES)
    assert decision["check"]["conclusion"] == "success"


def test_retry_leaves_a_real_newest_result_alone(monkeypatch):
    runs = [{"app": {"slug": "github-actions"}, "id": 21, "status": "completed", "conclusion": "action_required", "external_id": gate.OPENER_EXTERNAL_ID + "^main"},
            {"app": {"slug": "github-actions"}, "id": 22, "status": "completed", "conclusion": "success", "external_id": "qa-review-gate:trees:ginkgo-report=success^main"}]
    api = review_api(check_runs=runs, files=NEW_SPEC)
    monkeypatch.setattr(gate, "gh_api", api)
    gate.apply(gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review"), "o/r", "tok", "", "https://panel")
    assert [a for a, p in api.writes] == ["repos/o/r/check-runs"]


def no_report_api(files, known):
    runs = [{"app": {"slug": "github-actions"}, "id": 1, "external_id": "qa-review-gate:trees:" + known + "^main"}] if known else []
    return ci_api(files=files, artifacts=(), check_runs=runs)


def test_ci_run_without_a_report_keeps_the_other_tree_result(monkeypatch):
    files = [{"filename": OSS, "patch": '@@ -4,0 +5 @@\n+\tIt("oss", func() {'}]
    monkeypatch.setattr(gate, "gh_api", no_report_api(files, "oss-ginkgo-report=success"))
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok", trees=PRO_TREES)
    assert decision["check"]["conclusion"] == "success"
    assert decision["check"]["external_id"] == "qa-review-gate:trees:oss-ginkgo-report=success"
    assert "oss-ginkgo-report: success in an earlier run" in decision["check"]["summary"]


def test_ci_run_without_a_report_asks_a_person_only_for_the_tree_still_missing(monkeypatch):
    files = [{"filename": OSS, "patch": '@@ -4,0 +5 @@\n+\tIt("oss", func() {'},
             {"filename": "e2e/pro_test.go", "patch": '@@ -9,0 +10 @@\n+\tIt("pro", func() {'}]
    monkeypatch.setattr(gate, "gh_api", no_report_api(files, "oss-ginkgo-report=success"))
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok", trees=PRO_TREES)
    assert decision["check"]["conclusion"] == "action_required"
    assert "no ginkgo-report for 1 new spec(s)" in decision["check"]["title"]
    assert decision["check"]["external_id"] == "qa-review-gate:trees:oss-ginkgo-report=success"


def test_ci_jobs_of_one_tested_commit_are_serialized():
    # A PR run (head_sha) and a /test-e2e dispatch (sha in the title) of the same commit
    # must land in one queue, so the commit is resolved in a job before the group is chosen.
    text = pathlib.Path(__file__).parents[3].joinpath("workflows", "qa-review-gate.yaml").read_text()
    assert "group: qa-review-gate-${{ needs.tested.outputs.sha }}" in text
    assert "needs: tested" in text and "cancel-in-progress: false" in text
    assert "queue: max" in text  # two e2e completions may queue behind an active gate job
    assert "grep -oE '#[0-9]+\\b.*\\b[0-9a-f]{40}\\b' <<<\"$TITLE\" | grep -oE '[0-9a-f]{40}' | tail -n1" in text
    assert 'echo "sha=${sha:-${HEAD_SHA:-$RUN_ID}}"' in text  # a title without a SHA queues on the run head, as run_target reads it
    assert "    permissions:\n      pull-requests: read\n    outputs:" in text
    # A PR event job and the panel verdict job write to the same head as the e2e jobs do.
    assert "HEAD_SHA: ${{ github.event.workflow_run.head_sha || github.event.pull_request.head.sha }}" in text
    # A sweep run for one PR queues on that PR's current head, fails when it cannot read it,
    # and grades only while the PR still sits on it; the listing alone holds actions: write.
    assert 'sha="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha)" || { echo "::error::' in text
    assert "queued-sha: ${{ needs.tested.outputs.sha }}" in text
    assert "if: github.event_name == 'workflow_dispatch' && inputs.pr-number == ''" in text
    assert "caller-workflow: ${{ github.workflow_ref }}" in text
    assert text.count("\n      actions: write\n") == 1 and "\n      actions: read # the e2e report" in text


def test_bot_backport_keeps_the_title_the_panel_matches():
    decision = gate.decide_bot(backport_event(), BOTS, "qa-review")
    assert decision["checks"][0]["title"] == "QA review: automated backport, skipped"
    flake = gate.decide_bot(flake_fixer_event(), BOTS, "qa-review")
    assert flake["checks"][0]["title"] == "QA review: vcluster-qa-bot[bot] PR, skipped"


def test_retry_reconciles_an_existing_provisional_opener(monkeypatch):
    """The first attempt posted the opener, then its PATCH failed: the retry sees the opener
    at the first lookup, posts only qa-review, and still copies the real result onto it."""
    runs = [{"app": {"slug": "github-actions"}, "id": 20, "status": "completed", "conclusion": "success", "external_id": "^main", "output": {"title": "passed", "summary": "ok"}},
            {"app": {"slug": "github-actions"}, "id": 21, "status": "completed", "conclusion": "action_required", "external_id": gate.OPENER_EXTERNAL_ID + "^main"}]
    monkeypatch.setattr(gate, "gh_api", review_api(check_runs=runs, files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    assert "checks" not in decision and decision["reconcile"] == "qa-test-run"
    writes = []

    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": runs}
        if payload is not None:
            writes.append((args, payload))
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    gate.apply(decision, "o/r", "tok", "", "https://panel")
    posted = [p["name"] for a, p in writes if a[0].endswith("/check-runs")]
    assert posted == ["qa-review"]
    assert writes[-1][0] == ["repos/o/r/check-runs/21", "-X", "PATCH"]
    assert writes[-1][1]["conclusion"] == "success"


def test_apply_posts_every_check_in_the_decision(monkeypatch):
    calls = []
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: calls.append((args, payload)) or {})
    decision = gate.decide_bot(backport_event(), BOTS, "qa-review")
    gate.apply(decision, "loft-sh/loft-enterprise", "tok", "loft-sh/eng-qa", "https://run")
    posted = [p for a, p in calls if p]
    assert [p["name"] for p in posted] == ["qa-review", "qa-test-run"]
    assert all(p["head_sha"] == HEAD and p["conclusion"] == "success" for p in posted)
    assert all(p["external_id"] == "qa-review-gate:bot" for p in posted)


def test_apply_posts_check_run_and_requests_team(monkeypatch):
    calls = []
    lookups = pr_api()

    def fake_gh_api(args, token, payload=None):
        calls.append((args, payload))
        return lookups(args, token, payload)

    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review human", login="dev-x"), set(), "qa-review")
    head = gate.apply(decision, "loft-sh/vcluster-pro", "tok", "loft-sh/eng-qa", "https://run")
    assert head == HEAD
    check_call = next(p for a, p in calls if a[0] == "repos/loft-sh/vcluster-pro/check-runs")
    assert check_call["head_sha"] == HEAD and check_call["conclusion"] == "action_required"
    assert check_call["details_url"] == "https://run"
    team_call = next(p for a, p in calls if a[0].endswith("/requested_reviewers"))
    assert team_call == {"team_reviewers": ["eng-qa"]}


@pytest.mark.parametrize("reviews", [
    [],                                                       # the panel never graded this PR
    [panel_review(head=OTHER)],                               # graded an older head only
    [panel_review(submitted_at="2026-11-18T10:05:00Z")],      # graded this head after the comment
    [panel_review(login="dev-x")],                            # a person pasted a marker
    [{"user": {"login": "loft-bot"}, "body": "<!-- qa-review verdict=weird classes= head=" + HEAD + " base=main -->",
      "submitted_at": "2026-11-18T09:00:00Z"}],               # malformed marker is skipped
])
def test_override_binds_to_a_panel_verdict_on_the_current_head(monkeypatch, capsys, reviews):
    posted = []
    lookups = pr_api(reviews=reviews)

    def fake_gh_api(args, token, payload=None):
        if args[0].endswith("/check-runs"):
            posted.append(payload)
        if args[0].endswith("/comments"):
            replies.append(payload["body"])
            return {}
        return lookups(args, token, payload)

    replies = []
    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review override covered"), {"sowmyav27"}, "qa-review")
    assert gate.apply(decision, "o/r", "tok", "loft-sh/eng-qa", "https://run") is None
    assert posted == [] and "the override did nothing. I cannot tell if" in capsys.readouterr().out
    assert len(replies) == 1 and f"`/qa-review override {HEAD[:7]} <reason>`" in replies[0]
    assert not replies[0].startswith("/qa-review")  # the reply must not start the gate again


@pytest.mark.parametrize("runs, lands, says", [
    ([("2026-11-18T09:59:00Z", HEAD)], True, ""),                                  # this PR's CI ran on the head
    ([("2026-11-18T09:00:00Z", HEAD), ("2026-11-18T09:30:00Z", OTHER)], False,     # the head moved back to an older commit
     f"The PR head was `{OTHER[:7]}` when you commented and is `{HEAD[:7]}` now."),
    ([("2026-11-18T09:59:00Z", HEAD, 2)], False, "I cannot tell if"),              # another PR of the same branch and repo
    ([("2026-11-18T09:59:00Z", HEAD, None)], False, "I cannot tell if"),           # GitHub named no PR (a fork)
    ([], False, "I cannot tell if"),                                               # no run before the comment
])
def test_override_needs_no_panel_verdict_on_the_head_the_pr_had_at_the_comment(monkeypatch, runs, lands, says):
    posted, replies = [], []
    lookups = pr_api(reviews=[], runs=runs)

    def fake_gh_api(args, token, payload=None):
        if args[0].endswith("/check-runs"):
            posted.append(payload)
        if args[0].endswith("/comments"):
            replies.append(payload["body"])
            return {}
        if "/actions/runs?" in args[0] and runs and len(runs[0]) == 3:
            return {"workflow_runs": [{"created_at": at, "head_sha": sha, "pull_requests": [{"number": pr}] if pr else [],
                                       "head_repository": {"full_name": "o/r"}} for at, sha, pr in runs]}
        return lookups(args, token, payload)
    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review override covered"), {"sowmyav27"}, "qa-review")
    assert gate.apply(decision, "o/r", "tok", "", "https://run") == (HEAD if lands else None)
    assert len(posted) == (2 if lands else 0)
    assert (says in replies[0] and f"`/qa-review override {HEAD[:7]} <reason>`" in replies[0]) if says else not replies


def test_override_survives_a_failed_run_lookup_and_one_pr_read(monkeypatch):
    """The head is read once; a 503 on the run lookup asks for the sha instead of failing the job."""
    reads, replies = [], []
    lookups = pr_api(reviews=[])

    def fake_gh_api(args, token, payload=None):
        if "/actions/runs?" in args[0]:
            raise gate.GateError("gh api failed: 503")
        if args[0].endswith("/comments"):
            replies.append(payload["body"])
            return {}
        if args[0].endswith("/pulls/1"):
            reads.append(args[0])
        return lookups(args, token, payload)
    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review override covered"), {"sowmyav27"}, "qa-review")
    assert gate.apply(decision, "o/r", "tok", "", "https://run") is None
    assert len(reads) == 1 and "I cannot tell if" in replies[0]


def test_override_naming_a_stale_commit_says_so_on_the_pr(monkeypatch):
    replies = []
    lookups = pr_api(reviews=[])

    def fake_gh_api(args, token, payload=None):
        if args[0].endswith("/comments"):
            replies.append(payload["body"])
            return {}
        return lookups(args, token, payload)
    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event(f"/qa-review override {OTHER[:7]} covered"), {"sowmyav27"}, "qa-review")
    assert gate.apply(decision, "o/r", "tok", "loft-sh/eng-qa", "https://run") is None
    assert replies == [f"QA review gate: the override did nothing. The commit you named is not the PR head, which is `{HEAD[:7]}`."]


@pytest.mark.parametrize("body, expected", [
    ("/qa-review override covered", "is not an override login or team member"),
    ("/qa-review approve", "unknown /qa-review verb"),
    ("/qa-review", "use `/qa-review override [<reason>]` or `/qa-review human`"),
    ("thanks", None),  # not the command: the gate stays quiet
])
def test_main_replies_on_the_pr_when_a_command_did_nothing(tmp_path, monkeypatch, body, expected):
    replies = []
    event_file = tmp_path / "event.json"
    event_file.write_text(json.dumps(comment_event(body, login="dev-x")))
    for key, value in {"GITHUB_EVENT_PATH": str(event_file), "INPUT_MODE": "comment", "GITHUB_REPOSITORY": "o/r",
                       "INPUT_GITHUB_TOKEN": "tok", "INPUT_OVERRIDE_LOGINS": "sowmyav27"}.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setattr(gate, "gh_api", lambda args, token, payload=None: replies.append((args[0], payload["body"])) or {})
    assert gate.main() == 0
    if expected is None:
        assert replies == []
    else:
        assert replies[0][0].endswith("/issues/1/comments") and expected in replies[0][1]


def test_override_lands_on_the_head_the_panel_graded_before_the_comment(monkeypatch):
    posted = []
    lookups = pr_api(reviews=[panel_review(head=OTHER), panel_review()])

    def fake_gh_api(args, token, payload=None):
        if args[0].endswith("/check-runs"):
            posted.append(payload)
        return lookups(args, token, payload)

    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review override covered"), {"sowmyav27"}, "qa-review")
    assert gate.apply(decision, "o/r", "tok", "loft-sh/eng-qa", "https://run") == HEAD
    assert [c["head_sha"] for c in posted] == [HEAD, HEAD]


@pytest.mark.parametrize("body, lands", [
    (f"/qa-review override {HEAD} panel is down, I read it", True),
    (f"/qa-review override {HEAD[:7]} panel is down, I read it", True),
    (f"/qa-review override {OTHER[:12]} panel is down", False),
])
def test_override_may_name_the_head_when_the_panel_never_posted(monkeypatch, body, lands):
    posted = []
    lookups = pr_api(reviews=[])

    def fake_gh_api(args, token, payload=None):
        if args[0].endswith("/check-runs"):
            posted.append(payload)
        return lookups(args, token, payload)

    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event(body), {"sowmyav27"}, "qa-review")
    assert "panel is down" in decision["checks"][0]["summary"]
    assert gate.apply(decision, "o/r", "tok", "", "https://run") == (HEAD if lands else None)
    assert len(posted) == (2 if lands else 0)


def test_override_sha_alone_binds_to_that_head():
    decision = gate.decide_comment(comment_event(f"/qa-review override {HEAD}"), {"sowmyav27"}, "qa-review")
    assert decision["sha_prefix"] == HEAD and "no reason given" in decision["checks"][0]["summary"]


def test_human_request_needs_no_panel_verdict(monkeypatch):
    posted = []
    lookups = pr_api(reviews=[])

    def fake_gh_api(args, token, payload=None):
        if args[0].endswith("/check-runs"):
            posted.append(payload)
        return lookups(args, token, payload)

    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review human", login="dev-x"), set(), "qa-review")
    assert gate.apply(decision, "o/r", "tok", "", "https://run") == HEAD
    assert len(posted) == 1


def test_apply_warns_when_the_team_request_fails(monkeypatch, capsys):
    posted = []
    lookups = pr_api()

    def fake_gh_api(args, token, payload=None):
        if args[0].endswith("/requested_reviewers"):
            raise gate.GateError("gh api failed: Could not resolve to a node")
        if args[0].endswith("/check-runs"):
            posted.append(payload)
        return lookups(args, token, payload)

    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review human", login="dev-x"), set(), "qa-review")
    assert gate.apply(decision, "o/r", "tok", "loft-sh/eng-qa", "https://run") == HEAD
    assert len(posted) == 1 and "::warning::qa-review-gate: could not request loft-sh/eng-qa" in capsys.readouterr().out


def test_main_review_skip_prints_notice(tmp_path, monkeypatch, capsys):
    event_file = tmp_path / "event.json"
    event_file.write_text(json.dumps(review_event(login="anvesh-loft")))
    monkeypatch.setenv("GITHUB_EVENT_PATH", str(event_file))
    monkeypatch.setenv("INPUT_MODE", "review")
    monkeypatch.setenv("GITHUB_REPOSITORY", "loft-sh/vcluster-pro")
    monkeypatch.setenv("INPUT_GITHUB_TOKEN", "tok")
    assert gate.main() == 0
    assert "::notice::qa-review-gate: review by anvesh-loft" in capsys.readouterr().out


def test_main_rejects_unknown_mode(tmp_path, monkeypatch):
    event_file = tmp_path / "event.json"
    event_file.write_text("{}")
    monkeypatch.setenv("GITHUB_EVENT_PATH", str(event_file))
    monkeypatch.setenv("INPUT_MODE", "push")
    monkeypatch.setenv("GITHUB_REPOSITORY", "o/r")
    monkeypatch.setenv("INPUT_GITHUB_TOKEN", "tok")
    with pytest.raises(gate.GateError):
        gate.main()


DIFF = """diff --git a/e2e/suites/snapshot/snapshot.go b/e2e/suites/snapshot/snapshot.go
+++ b/e2e/suites/snapshot/snapshot.go
@@ -10,3 +10,9 @@
+	It("restores the snapshot", func() {
+	FIt("creates a snapshot", func() {
 	It("already there", func() {
-	It("removed", func() {
+	Specify("keeps the \\"quoted\\" name", func() {
@@ -40,2 +46,3 @@
 	DescribeTable("quota", func(n int) {},
+		Entry("rejects over quota", 2),
 	)
diff --git a/pkg/thing_test.go b/pkg/thing_test.go
+++ b/pkg/thing_test.go
@@ -1,0 +1,1 @@
+	It("unit spec, not e2e", func() {
"""
SNAPSHOT = "e2e/suites/snapshot/snapshot.go"


def test_added_specs_reads_added_specs_with_their_line_in_e2e_go_only():
    assert gate.added_specs(DIFF) == [
        {"path": SNAPSHOT, "line": 10, "text": "restores the snapshot"},
        {"path": SNAPSHOT, "line": 11, "text": "creates a snapshot"},
        {"path": SNAPSHOT, "line": 13, "text": 'keeps the "quoted" name'},
        {"path": SNAPSHOT, "line": 47, "text": "rejects over quota"},
    ]


def test_unescape_go_reads_the_literal_like_go():
    assert gate.unescape_go(r'a \"b\" \\ c\n') == 'a "b" \\ c\n'


RUNNER = "/home/runner/work/r/r/"


def leaf(line, state, text="x", file=RUNNER + SNAPSHOT, kind="It"):
    return {"LeafNodeType": kind, "LeafNodeText": text, "State": state,
            "LeafNodeLocation": {"FileName": file, "LineNumber": line}}


def test_report_specs_maps_leaf_location_to_state():
    report = [{"SpecReports": [leaf(10, "passed"), leaf(11, "skipped"),
                               leaf(0, "passed", kind="BeforeSuite", file="")]}]
    assert gate.report_specs(report) == {(RUNNER + SNAPSHOT, 10): "passed",
                                         (RUNNER + SNAPSHOT, 11): "skipped"}


def test_report_specs_keeps_the_worst_state_across_reports():
    states = gate.report_specs([{"SpecReports": [leaf(10, "failed"), leaf(11, "skipped")]}])
    gate.report_specs([{"SpecReports": [leaf(10, "passed"), leaf(11, "passed")]}], states)
    assert states == {(RUNNER + SNAPSHOT, 10): "failed", (RUNNER + SNAPSHOT, 11): "skipped"}


def test_spec_state_matches_file_suffix_and_line_not_text():
    states = gate.report_specs([{"SpecReports": [
        leaf(10, "passed", text="same text"),
        leaf(99, "skipped", text="same text", file=RUNNER + "e2e/other/other.go")]}])
    new = {"path": SNAPSHOT, "line": 10, "text": "same text"}
    assert gate.spec_state(states, new) == "passed"
    assert gate.spec_state(states, {**new, "line": 11}) is None
    assert gate.spec_state(states, {**new, "path": "other/snapshot.go"}) is None


def run(conclusion="success"):
    return {"app": {"slug": "github-actions"}, "id": 7, "conclusion": conclusion, "head_sha": HEAD,
            "html_url": "https://github.com/o/r/actions/runs/7"}


def spec(line, text):
    return {"path": SNAPSHOT, "line": line, "text": text}


def test_ci_all_new_specs_passed_is_success():
    states = gate.report_specs([{"SpecReports": [leaf(10, "passed"), leaf(11, "passed")]}])
    decision = gate.decide_ci(run(), 1, [spec(10, "a"), spec(11, "b")], states)
    assert decision["check"]["name"] == "qa-test-run"
    assert decision["check"]["conclusion"] == "success"
    assert decision["check"]["head_sha"] == HEAD


def test_ci_missing_or_skipped_spec_is_failure_and_names_it():
    states = gate.report_specs([{"SpecReports": [leaf(10, "passed"), leaf(11, "skipped")]}])
    decision = gate.decide_ci(run("failure"), 1, [spec(10, "a"), spec(11, "b"), spec(12, "c")],
                              states)
    assert decision["check"]["conclusion"] == "failure"
    assert f"did not run: {SNAPSHOT}:12 c" in decision["check"]["summary"]
    assert f"{SNAPSHOT}:11 b (skipped)" in decision["check"]["summary"]
    assert "2 new spec(s)" in decision["check"]["title"]


@pytest.mark.parametrize("conclusion", ["cancelled", "timed_out", None])
def test_ci_skips_when_the_run_did_not_finish(conclusion):
    assert "skip" in gate.decide_ci(run(conclusion), 1, [spec(1, "a")], {})


def test_ci_skips_when_the_pr_adds_no_spec():
    assert "skip" in gate.decide_ci(run(), 1, [], {})


def test_missing_patch_for_added_e2e_file_cannot_pass(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", review_api(files=[{"filename": "e2e/big.go", "additions": 1}]))
    check = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")["checks"][1]
    assert check["conclusion"] == "action_required"
    assert "No usable diff for e2e/big.go" in check["summary"]
    assert "/test-e2e <label-filter>" in check["summary"]


def test_reconciliation_ignores_other_provisional_openers(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", review_api(files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    writes = []
    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": [
                {"app": {"slug": "github-actions"}, "id": 20, "status": "completed", "conclusion": "success", "output": {"title": "passed", "summary": "passed"}},
                {"app": {"slug": "github-actions"}, "id": 21, "status": "completed", "conclusion": "action_required", "external_id": gate.OPENER_EXTERNAL_ID},
            ] if "filter=all" in args[0] else []}
        if payload is not None:
            writes.append((args, payload))
            return {"id": 22}
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    gate.apply(decision, "o/r", "tok", "", "https://panel")
    assert writes[-2][1]["external_id"] == gate.OPENER_EXTERNAL_ID + "^main"
    assert writes[-1][1]["conclusion"] == "success"

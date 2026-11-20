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


def marker(verdict="block", classes="a:0,b:1,c:2,d:0", head=HEAD):
    return f"Panel review: 3 blocking.\n\n<!-- qa-review verdict={verdict} classes={classes} head={head} -->"


def review_event(login="loft-bot", body=None, head=HEAD):
    return {
        "review": {"user": {"login": login}, "body": marker() if body is None else body,
                   "html_url": "https://github.com/o/r/pull/1#pullrequestreview-9"},
        "pull_request": {"number": 1, "head": {"sha": head}},
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
    return {"action": action, "pull_request": pr or backport_pr(), "sender": {"login": sender}}


def panel_review(head=HEAD, submitted_at="2026-11-18T09:00:00Z", login="loft-bot"):
    return {"user": {"login": login}, "body": marker(head=head), "submitted_at": submitted_at}


def pr_api(reviews=None):
    """A fake gh_api for the PR lookups apply makes: the head, then the PR's reviews."""
    def fake(args, token, payload=None):
        if args[0].endswith("/reviews"):
            return [[panel_review()] if reviews is None else reviews]
        if "/pulls/" in args[0] and len(args) == 1:
            return {"head": {"sha": HEAD}}
        return {}
    return fake


def test_parse_marker_reads_verdict_classes_and_head():
    assert gate.parse_marker(marker()) == ("block", {"a": 0, "b": 1, "c": 2, "d": 0}, HEAD)


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
            return {"head": {"sha": HEAD}, "user": {"login": author}}
        return {}
    fake.writes = writes
    return fake


NEW_SPEC = [{"filename": "e2e/a.go", "patch": '@@ -1,0 +1 @@\n+\tIt("new", func() {'}]


def test_review_opens_the_test_run_check_green_when_the_pr_adds_no_spec(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", review_api(files=[]))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    assert [(c["name"], c["conclusion"]) for c in decision["checks"]] == [
        ("qa-review", "failure"), ("qa-test-run", "success")]


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
    completed = review_api(check_runs=[{"conclusion": "success"}], files=NEW_SPEC)
    monkeypatch.setattr(gate, "gh_api", completed)
    gate.apply(decision, "o/r", "tok", "", "https://run")
    assert [payload["name"] for _, payload in completed.writes] == ["qa-review"]


@pytest.mark.parametrize("conclusion", ["success", "failure", "action_required"])
def test_review_opener_reconciles_result_posted_between_lookup_and_create(monkeypatch, conclusion):
    monkeypatch.setattr(gate, "gh_api", review_api(files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    writes = []
    result = {"id": 20, "status": "completed", "conclusion": conclusion,
              "details_url": "https://e2e", "output": {"title": "E2E result", "summary": "details"}}

    def api(args, token, payload=None):
        if "check-runs?" in args[0]:
            return {"check_runs": [result, {"id": 21, "status": "completed"}]
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


def test_review_leaves_an_existing_test_run_check_alone(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", review_api(check_runs=[{"conclusion": "success"}], files=NEW_SPEC))
    decision = gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review")
    assert "checks" not in decision and decision["check"]["name"] == "qa-review"


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


def test_backport_by_the_bot_gets_both_checks_green():
    decision = gate.decide_bot(backport_event(), BOTS, "qa-review")
    names = [(c["name"], c["conclusion"], c["head_sha"]) for c in decision["checks"]]
    assert names == [("qa-review", "success", HEAD), ("qa-test-run", "success", HEAD)]
    assert decision["request_qa_review"] is False and decision["pr_number"] == 9444


@pytest.mark.parametrize("pr", [backport_pr(login="roehrijn"), backport_pr(ref="fix/thing")])
def test_backport_needs_the_bot_author_and_the_backport_branch(pr):
    assert "skip" in gate.decide_bot(backport_event(pr), BOTS, "qa-review")


@pytest.mark.parametrize("event", [backport_event(sender="roehrijn"),
                                   backport_event(action="synchronize"),
                                   backport_event(action="synchronize", sender="roehrijn")])
def test_only_the_head_the_bot_opened_gets_a_free_pass(event):
    decision = gate.decide_bot(event, BOTS, "qa-review")
    assert decision == {"skip": "only the head the bot opened the PR with passes; the panel reviews this head"}


def test_panel_verdict_on_a_backport_counts():
    event = review_event(body=marker("block"))
    event["pull_request"] = backport_pr()
    assert gate.decide_review(event, "loft-bot", "qa-review")["check"]["conclusion"] == "failure"


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
            return {"artifacts": [{"name": a} for a in artifacts]}
        if "/check-runs?" in args[0]:
            return {"check_runs": list(check_runs)}
        return {"head": {"sha": head}, "base": {"ref": "main"}}
    return fake


def ci_run(number=9):
    return {"id": 7, "pull_requests": [{"number": number}], "head_sha": HEAD, "conclusion": "success"}


def test_ci_diff_failure_asks_a_person_instead_of_failing_the_job(monkeypatch):
    monkeypatch.setattr(gate, "gh_api", ci_api())
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok")
    assert decision["check"]["name"] == "qa-test-run"
    assert decision["check"]["conclusion"] == "action_required"
    assert decision["check"]["head_sha"] == HEAD and decision["pr_number"] == 9
    assert "/test-e2e" in decision["check"]["summary"]


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
    monkeypatch.setattr(gate, "gh", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no download without an artifact")))
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok")
    assert decision["check"]["conclusion"] == "action_required"
    assert "no ginkgo-report for 1 new spec(s)" in decision["check"]["title"]
    assert "uploaded no report" in decision["check"]["summary"]
    assert "`/test-e2e <label-filter>`" in decision["check"]["summary"]


def test_ci_unreadable_report_asks_a_person(monkeypatch):
    files = [{"filename": "e2e/a.go", "patch": '@@ -1,0 +1 @@\n+\tIt("new", func() {'}]
    monkeypatch.setattr(gate, "gh_api", ci_api(files=files))

    def broken(args, token, **kwargs):
        raise gate.GateError("gh run download failed: zip is corrupt")
    monkeypatch.setattr(gate, "gh", broken)
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok")
    assert decision["check"]["conclusion"] == "action_required"
    assert "ginkgo-report could not be read" in decision["check"]["title"]
    assert "zip is corrupt" in decision["check"]["summary"]


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
    runs = [{"id": 1, "external_id": "qa-review-gate:trees:ginkgo-report=success"},
            {"id": 2, "external_id": gate.OPENER_EXTERNAL_ID}]
    monkeypatch.setattr(gate, "gh_api", ci_api(files=files, artifacts=("oss-ginkgo-report",), check_runs=runs))
    report = [{"SpecReports": [leaf(5, "passed", file=RUNNER + OSS)]}]

    def download(args, token, **kwargs):
        dest = args[args.index("-D") + 1]
        os.makedirs(dest, exist_ok=True)
        pathlib.Path(dest, "report.json").write_text(json.dumps(report))
        return ""
    monkeypatch.setattr(gate, "gh", download)
    decision = gate.collect_ci({"workflow_run": ci_run()}, "o/r", "tok", trees=PRO_TREES)
    assert decision["check"]["conclusion"] == "success"


def test_retry_leaves_a_real_newest_result_alone(monkeypatch):
    runs = [{"id": 21, "status": "completed", "conclusion": "action_required", "external_id": gate.OPENER_EXTERNAL_ID},
            {"id": 22, "status": "completed", "conclusion": "success", "external_id": "qa-review-gate:trees:ginkgo-report=success"}]
    api = review_api(check_runs=runs, files=NEW_SPEC)
    monkeypatch.setattr(gate, "gh_api", api)
    gate.apply(gate.collect_review(review_event(), "o/r", "tok", "loft-bot", "qa-review"), "o/r", "tok", "", "https://panel")
    assert [a for a, p in api.writes] == ["repos/o/r/check-runs"]


def no_report_api(files, known):
    runs = [{"id": 1, "external_id": "qa-review-gate:trees:" + known}] if known else []
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


def test_ci_jobs_of_one_head_are_serialized():
    text = pathlib.Path(__file__).parents[3].joinpath("workflows", "qa-review-gate.yaml").read_text()
    assert "group: qa-review-gate-${{ github.event.workflow_run.head_sha || github.run_id }}" in text
    assert "cancel-in-progress: false" in text


def test_bot_backport_title_names_the_backport():
    decision = gate.decide_bot(backport_event(), BOTS, "qa-review")
    assert decision["checks"][0]["title"] == "QA review: automated backport, skipped"
    flake = gate.decide_bot(flake_fixer_event(), BOTS, "qa-review")
    assert flake["checks"][0]["title"] == "QA review: vcluster-qa-bot[bot] PR, skipped"


def test_retry_reconciles_an_existing_provisional_opener(monkeypatch):
    """The first attempt posted the opener, then its PATCH failed: the retry sees the opener
    at the first lookup, posts only qa-review, and still copies the real result onto it."""
    runs = [{"id": 20, "status": "completed", "conclusion": "success", "output": {"title": "passed", "summary": "ok"}},
            {"id": 21, "status": "completed", "conclusion": "action_required", "external_id": gate.OPENER_EXTERNAL_ID}]
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
    assert [p["name"] for a, p in calls] == ["qa-review", "qa-test-run"]
    assert all(p["head_sha"] == HEAD and p["conclusion"] == "success" for a, p in calls)


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
    [{"user": {"login": "loft-bot"}, "body": "<!-- qa-review verdict=weird classes= head=" + HEAD + " -->",
      "submitted_at": "2026-11-18T09:00:00Z"}],               # malformed marker is skipped
])
def test_override_binds_to_a_panel_verdict_on_the_current_head(monkeypatch, capsys, reviews):
    posted = []
    lookups = pr_api(reviews=reviews)

    def fake_gh_api(args, token, payload=None):
        if args[0].endswith("/check-runs"):
            posted.append(payload)
        return lookups(args, token, payload)

    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review override covered"), {"sowmyav27"}, "qa-review")
    assert gate.apply(decision, "o/r", "tok", "loft-sh/eng-qa", "https://run") is None
    assert posted == [] and "no panel verdict on the PR's current head" in capsys.readouterr().out


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
    return {"id": 7, "conclusion": conclusion, "head_sha": HEAD,
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
                {"id": 20, "status": "completed", "conclusion": "success", "output": {"title": "passed", "summary": "passed"}},
                {"id": 21, "status": "completed", "conclusion": "action_required", "external_id": gate.OPENER_EXTERNAL_ID},
            ] if "filter=all" in args[0] else []}
        if payload is not None:
            writes.append((args, payload))
            return {"id": 22}
        return {}
    monkeypatch.setattr(gate, "gh_api", api)
    gate.apply(decision, "o/r", "tok", "", "https://panel")
    assert writes[-2][1]["external_id"] == gate.OPENER_EXTERNAL_ID
    assert writes[-1][1]["conclusion"] == "success"

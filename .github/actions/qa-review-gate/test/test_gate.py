import importlib.util
import json
import pathlib

import pytest

SRC = pathlib.Path(__file__).resolve().parents[1] / "src" / "gate.py"
spec = importlib.util.spec_from_file_location("gate", SRC)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

HEAD = "a" * 40
OTHER = "b" * 40


def marker(verdict="block", classes="a:0,b:1,c:2,d:0", head=HEAD):
    return f"Panel review: 3 blocking.\n\n<!-- qa-review verdict={verdict} classes={classes} head={head} -->"


def review_event(login="loft-bot", body=None, head=HEAD):
    return {
        "review": {"user": {"login": login}, "body": marker() if body is None else body,
                   "html_url": "https://github.com/o/r/pull/1#pullrequestreview-9"},
        "pull_request": {"number": 1, "head": {"sha": head}},
    }


def comment_event(body, login="sowmyav27", association="MEMBER", on_pr=True):
    return {
        "issue": {"number": 1, **({"pull_request": {"url": "x"}} if on_pr else {})},
        "comment": {"body": body, "user": {"login": login}, "author_association": association,
                    "html_url": "https://github.com/o/r/pull/1#issuecomment-5"},
    }


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


@pytest.mark.parametrize("verdict,conclusion,ask", [
    ("pass", "success", False), ("needs_human", "action_required", True), ("not_run", "neutral", False),
])
def test_review_verdict_mapping(verdict, conclusion, ask):
    event = review_event(body=marker(verdict=verdict, classes=""))
    decision = gate.decide_review(event, "loft-bot", "qa-review")
    assert decision["check"]["conclusion"] == conclusion
    assert decision["request_qa_review"] is ask


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
    assert decision["check"]["conclusion"] == "success"
    assert decision["check"]["head_sha"] is None
    assert "overrode the panel verdict: the spec is covered" in decision["check"]["summary"]
    assert decision["pr_number"] == 1


def test_override_by_non_qa_login_is_ignored():
    event = comment_event("/qa-review override trust me", login="someone-else")
    assert "skip" in gate.decide_comment(event, {"sowmyav27"}, "qa-review")


def test_override_without_reason_is_ignored():
    assert "skip" in gate.decide_comment(comment_event("/qa-review override"), {"sowmyav27"}, "qa-review")


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


def test_apply_posts_check_run_and_requests_team(monkeypatch):
    calls = []

    def fake_gh_api(args, token, payload=None):
        calls.append((args, payload))
        if args[0].endswith("/pulls/1"):
            return {"head": {"sha": HEAD}}
        return {}

    monkeypatch.setattr(gate, "gh_api", fake_gh_api)
    decision = gate.decide_comment(comment_event("/qa-review human", login="dev-x"), set(), "qa-review")
    head = gate.apply(decision, "loft-sh/vcluster-pro", "tok", "loft-sh/eng-qa", "https://run")
    assert head == HEAD
    check_call = next(p for a, p in calls if a[0] == "repos/loft-sh/vcluster-pro/check-runs")
    assert check_call["head_sha"] == HEAD and check_call["conclusion"] == "action_required"
    assert check_call["details_url"] == "https://run"
    team_call = next(p for a, p in calls if a[0].endswith("/requested_reviewers"))
    assert team_call == {"team_reviewers": ["eng-qa"]}


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
    with pytest.raises(gate.GateError):
        gate.main()


DIFF = """diff --git a/e2e/suites/snapshot/snapshot.go b/e2e/suites/snapshot/snapshot.go
+++ b/e2e/suites/snapshot/snapshot.go
@@ -1,3 +1,9 @@
+	It("restores the snapshot", func() {
+	FIt("creates a snapshot", func() {
 	It("already there", func() {
-	It("removed", func() {
+	Specify("keeps the \\"quoted\\" name", func() {
diff --git a/pkg/thing_test.go b/pkg/thing_test.go
+++ b/pkg/thing_test.go
+	It("unit spec, not e2e", func() {
"""


def test_added_specs_reads_added_it_lines_in_e2e_go_only():
    assert gate.added_specs(DIFF) == ["restores the snapshot", "creates a snapshot",
                                      'keeps the \\"quoted\\" name']


def test_report_specs_maps_leaf_text_to_state():
    report = [{"SpecReports": [
        {"LeafNodeType": "It", "LeafNodeText": "restores the snapshot", "State": "passed"},
        {"LeafNodeType": "It", "LeafNodeText": "creates a snapshot", "State": "skipped"},
        {"LeafNodeType": "BeforeSuite", "LeafNodeText": "", "State": "passed"},
    ]}]
    assert gate.report_specs(report) == {"restores the snapshot": "passed",
                                         "creates a snapshot": "skipped"}


def run(conclusion="success"):
    return {"id": 7, "conclusion": conclusion, "head_sha": HEAD,
            "html_url": "https://github.com/o/r/actions/runs/7"}


def test_ci_all_new_specs_passed_is_success():
    decision = gate.decide_ci(run(), 1, ["a", "b"], {"a": "passed", "b": "passed"}, "qa-review")
    assert decision["check"]["name"] == "qa-review-ci"
    assert decision["check"]["conclusion"] == "success"
    assert decision["check"]["head_sha"] == HEAD


def test_ci_missing_or_skipped_spec_is_failure_and_names_it():
    decision = gate.decide_ci(run("failure"), 1, ["a", "b", "c"],
                              {"a": "passed", "b": "skipped"}, "qa-review")
    assert decision["check"]["conclusion"] == "failure"
    assert "did not run: c" in decision["check"]["summary"]
    assert "b (skipped)" in decision["check"]["summary"]
    assert "2 new spec(s)" in decision["check"]["title"]


@pytest.mark.parametrize("conclusion", ["cancelled", "timed_out", None])
def test_ci_skips_when_the_run_did_not_finish(conclusion):
    assert "skip" in gate.decide_ci(run(conclusion), 1, ["a"], {}, "qa-review")


def test_ci_skips_when_the_pr_adds_no_spec():
    assert "skip" in gate.decide_ci(run(), 1, [], {}, "qa-review")

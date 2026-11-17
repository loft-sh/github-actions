"""Offline policy and transport regression tests for completion-driven approval."""

import copy
import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "completion", Path(__file__).parents[1] / "src/on-ci-completion.py")
completion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(completion)

REPO = "loft-sh/example"
SHA = "a" * 40


def check(name="build", conclusion="success", app=15368, id=1, status="completed"):
    return {"name": name, "conclusion": conclusion, "app": {"id": app},
            "id": id, "status": status, "started_at": "2026-11-17T10:00:00Z"}


class FakeGitHub:
    def __init__(self):
        self.pr = {"number": 123, "state": "open", "draft": False, "mergeable": True,
                   "user": {"login": "loft-bot"}, "labels": [],
                   "head": {"sha": SHA, "ref": "backport/release-5.0/pr-1",
                            "repo": {"full_name": REPO}},
                   "base": {"ref": "release-5.0", "sha": "b" * 40,
                            "repo": {"full_name": REPO}}}
        self.classic = {"requiresStatusChecks": True, "requiredStatusChecks": [
            {"context": "build", "app": {"databaseId": 15368}}]}
        self.rules = []
        self.runs = [check()]
        self.statuses = []
        self.reviews = []
        self.writes = []
        self.pr_reads = 0
        self.mutate = lambda pr: None
        self.fail_path = None
        self.login = "approver"

    def api(self, path, payload=None, paginate=False):
        if self.fail_path and self.fail_path in path:
            raise RuntimeError("API unavailable")
        if path == "graphql":
            return {"data": {"repository": {"ref": {"branchProtectionRule": self.classic}}}}
        if path.endswith("/reviews") and payload:
            self.writes.append(payload)
            review = {"id": len(self.reviews) + 1, "user": {"login": "approver"},
                      "state": "APPROVED", "commit_id": payload["commit_id"]}
            self.reviews.append(review)
            return review
        if path.endswith("/pulls/123"):
            self.pr_reads += 1
            if self.pr_reads > 1:
                self.mutate(self.pr)
            return copy.deepcopy(self.pr)
        if path == "user":
            return {"login": self.login}
        raise AssertionError(f"unexpected API path: {path}")

    def items(self, path, key=None):
        if self.fail_path and self.fail_path in path:
            raise RuntimeError("API unavailable")
        if "/rules/branches/" in path:
            return self.rules
        if "/check-runs?" in path:
            return self.runs
        if "/statuses?" in path:
            return self.statuses
        if "/reviews?" in path:
            return self.reviews
        if "/commits/" in path and "/pulls?" in path:
            return [{"number": 123}]
        raise AssertionError(f"unexpected list path: {path}")


class CompletionTests(unittest.TestCase):
    def setUp(self):
        printer = patch("builtins.print")
        printer.start()
        self.addCleanup(printer.stop)
        self.api = FakeGitHub()
        self.event = {"action": "completed", "workflow_run": {
            "event": "pull_request", "status": "completed", "head_sha": SHA,
            "head_branch": "backport/release-5.0/pr-1",
            "head_repository": {"full_name": REPO}, "pull_requests": []}}

    def evaluate(self):
        completion.evaluate(self.api, self.api, REPO, self.event, {"loft-bot"}, {"manual"})

    def test_green_completion_approves_exact_sha_and_duplicate_is_noop(self):
        self.evaluate()
        self.evaluate()
        self.assertEqual(len(self.api.writes), 1)
        self.assertEqual(self.api.writes[0]["commit_id"], SHA)
        self.assertEqual(self.api.pr_reads, 3)

    def test_missing_pending_failed_cancelled_and_unknown_conclusions_block(self):
        for runs in ([], [check(status="queued", conclusion=None)],
                     *([check(conclusion=c)] for c in ("failure", "timed_out", "cancelled", "stale", None))):
            with self.subTest(runs=runs):
                self.api.runs = runs
                self.evaluate()
                self.assertEqual(self.api.writes, [])

    def test_wrong_app_cannot_satisfy_requirement(self):
        self.api.runs = [check(app=99)]
        self.evaluate()
        self.assertEqual(self.api.writes, [])

    def test_optional_failure_does_not_gate(self):
        self.api.runs.append(check("optional e2e", "failure", id=2))
        self.evaluate()
        self.assertEqual(len(self.api.writes), 1)

    def test_skipped_rerun_cannot_hide_failure_but_successful_rerun_can(self):
        self.api.runs = [check(conclusion="failure"), check(conclusion="skipped", id=2)]
        self.evaluate()
        self.assertEqual(self.api.writes, [])
        self.api.runs.append(check(id=3))
        self.evaluate()
        self.assertEqual(len(self.api.writes), 1)

    def test_pending_rerun_cannot_reuse_previous_success(self):
        self.api.runs.append(check(status="queued", conclusion=None, id=2))
        self.evaluate()
        self.assertEqual(self.api.writes, [])

    def test_current_eligibility_is_required(self):
        changes = [lambda p: p.update(state="closed"), lambda p: p.update(draft=True),
                   lambda p: p["user"].update(login="human"),
                   lambda p: p["head"].update(sha="c" * 40),
                   lambda p: p["head"].update(ref="renovate/deps"),
                   lambda p: p["head"]["repo"].update(full_name="fork/example"),
                   lambda p: p.update(labels=[{"name": "MANUAL"}]),
                   lambda p: p.update(mergeable=False), lambda p: p.update(mergeable=None)]
        for change in changes:
            with self.subTest(change=change):
                self.api = FakeGitHub()
                change(self.api.pr)
                self.evaluate()
                self.assertEqual(self.api.writes, [])

    def test_racing_head_base_author_or_labels_block(self):
        for change in (lambda p: p["head"].update(sha="c" * 40),
                       lambda p: p["base"].update(sha="c" * 40),
                       lambda p: p["base"].update(ref="main"),
                       lambda p: p["user"].update(login="human"),
                       lambda p: p.update(labels=[{"name": "manual"}])):
            with self.subTest(change=change):
                self.api = FakeGitHub()
                self.api.mutate = change
                self.evaluate()
                self.assertEqual(self.api.writes, [])

    def test_non_pr_fork_and_non_backport_events_skip_without_reads(self):
        for field, value in (("event", "push"), ("status", "in_progress"),
                             ("head_branch", "renovate/deps"),
                             ("head_repository", {"full_name": "fork/example"})):
            with self.subTest(field=field):
                event = copy.deepcopy(self.event)
                event["workflow_run"][field] = value
                completion.evaluate(self.api, self.api, REPO, event, {"loft-bot"}, set())
                self.assertEqual(self.api.pr_reads, 0)

    def test_ruleset_requirements_are_added_to_classic_protection(self):
        self.api.rules = [{"type": "required_status_checks", "parameters": {
            "required_status_checks": [{"context": "lint", "integration_id": 15368}]}}]
        self.evaluate()
        self.assertEqual(self.api.writes, [])
        self.api.runs.append(check("lint"))
        self.evaluate()
        self.assertEqual(len(self.api.writes), 1)

    def test_empty_gate_refuses_approval(self):
        self.api.classic = None
        self.evaluate()
        self.assertEqual(self.api.writes, [])

    def test_api_failures_propagate_without_approval(self):
        for endpoint in ("graphql", "/rules/", "/check-runs?", "/statuses?", "/reviews?"):
            with self.subTest(endpoint=endpoint):
                self.api.fail_path = endpoint
                with self.assertRaises(RuntimeError):
                    self.evaluate()
                self.assertEqual(self.api.writes, [])

    def test_required_commit_status_cannot_be_hidden_by_check_success(self):
        self.api.statuses = [{"context": "build", "id": 1, "state": "failure"}]
        self.evaluate()
        self.assertEqual(self.api.writes, [])

    def test_unpinned_legacy_status_can_satisfy_requirement(self):
        self.api.classic["requiredStatusChecks"][0]["app"] = None
        self.api.runs = []
        self.api.statuses = [{"context": "build", "id": 1, "state": "pending"}]
        self.evaluate()
        self.assertEqual(self.api.writes, [])
        self.api.statuses.append({"context": "build", "id": 2, "state": "success"})
        self.evaluate()
        self.assertEqual(len(self.api.writes), 1)

    def test_dismissed_approval_does_not_deduplicate(self):
        self.api.reviews = [{"id": 1, "state": "DISMISSED", "commit_id": SHA,
                             "user": {"login": "approver"}}]
        self.evaluate()
        self.assertEqual(len(self.api.writes), 1)

    def test_self_approval_is_rejected(self):
        self.api.login = "loft-bot"
        self.evaluate()
        self.assertEqual(self.api.writes, [])

    def test_old_commit_approval_does_not_deduplicate(self):
        self.api.reviews = [{"id": 1, "state": "APPROVED", "commit_id": "b" * 40,
                             "user": {"login": "approver"}}]
        self.evaluate()
        self.assertEqual(len(self.api.writes), 1)

    def test_required_workflow_rule_refuses_unverified_gate(self):
        self.api.rules = [{"type": "workflows"}]
        self.evaluate()
        self.assertEqual(self.api.writes, [])

    def test_test_merge_failure_blocks_green_head(self):
        self.api.pr["merge_commit_sha"] = "d" * 40
        original = self.api.items

        def items(path, key=None):
            if "d" * 40 in path and "check-runs" in path:
                return [check(conclusion="failure")]
            return original(path, key)

        self.api.items = items
        self.evaluate()
        self.assertEqual(self.api.writes, [])


class TransportTests(unittest.TestCase):
    @patch.object(completion.subprocess, "run")
    def test_all_pages_are_consumed_with_read_identity(self, run):
        run.return_value.stdout = json.dumps([{"check_runs": [{"id": 1}]},
                                             {"check_runs": [{"id": 2}]}])
        api = completion.GitHub("read-token")
        self.assertEqual(api.items("repos/o/r/commits/sha/check-runs", "check_runs"),
                         [{"id": 1}, {"id": 2}])
        args, kwargs = run.call_args
        self.assertIn("--paginate", args[0])
        self.assertIn("--slurp", args[0])
        self.assertEqual(kwargs["env"]["GH_TOKEN"], "read-token")

    @patch.object(completion.subprocess, "run")
    def test_graphql_errors_do_not_become_empty_gate(self, run):
        run.return_value.stdout = '{"data":null,"errors":[{"message":"denied"}]}'
        with self.assertRaises(ValueError):
            completion.GitHub("read-token").api("graphql", {"query": "query {}"})

    @patch.dict(os.environ, {"GITHUB_EVENT_NAME": "workflow_run"}, clear=True)
    def test_missing_configuration_is_annotated_without_crashing(self):
        with patch("builtins.print") as printer:
            completion.main()
        self.assertIn("::warning::Completion approval skipped", printer.call_args.args[0])


if __name__ == "__main__":
    unittest.main()

"""Turn the review panel's verdict, or a QA override comment, into the qa-review check-run.

Two event shapes, both read from GITHUB_EVENT_PATH:

- pull_request_review (submitted): the panel bot's review body ends with a marker line
  `<!-- qa-review verdict=<v> classes=a:N,b:N,c:N,d:N head=<sha> -->`. The verdict becomes the
  check-run conclusion on that head. A review from anyone else, or a marker for another head,
  is ignored.
- issue_comment (created): `/qa-review override <reason>` from a QA login completes the
  check-run as success and records who overrode it. `/qa-review human` from a repository
  member asks the QA team for a review and leaves the check-run waiting for a person.
- workflow_run (completed) of the e2e workflow: every `It(` the PR adds is looked up in the
  Ginkgo JSON report the run uploaded. A new spec that did not run, or did not pass, turns the
  `<check>-ci` check-run red. The panel's verdict check-run is never touched.
- pull_request (opened, synchronize, ...) of an automated backport: a PR the panel bot opened
  from a `backport/` branch was reviewed on main already. While every push comes from the bot,
  both check-runs complete as success at once, so the repo's auto-approve workflow can approve
  it without waiting on the panel. A push by anyone else gets no free pass: that head has no
  check-run until the panel reviews it and the e2e run reports.

Every decision is a plain dict so the tests never touch the network; `apply` is the only
function that calls `gh`.
"""

import glob
import json
import os
import re
import subprocess
import sys
import tempfile

MARKER = re.compile(
    r"<!--\s*qa-review\s+verdict=(?P<verdict>[a-z_]+)\s+classes=(?P<classes>\S*)"
    r"\s+head=(?P<head>[0-9a-f]{40})\s*-->"
)
CONCLUSION = {"block": "failure", "pass": "success", "needs_human": "action_required",
              "not_run": "action_required"}
CLASS_WORDS = {"a": "need a test", "b": "weak test", "c": "no test", "d": "product gap"}
MEMBER_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
ADDED_SPEC = re.compile(r'^\+[^+].*\b[FPX]?(?:It|Specify)\(\s*"((?:[^"\\]|\\.)+)"')
GO_ESCAPES = {"n": "\n", "t": "\t", "r": "\r"}
# Ginkgo states, worst last; two reports for one spec text keep the worst.
STATE_RANK = {"passed": 0, "": 1, "pending": 2, "skipped": 3, "timedout": 4, "interrupted": 4,
              "aborted": 4, "panicked": 5, "failed": 5}
REPORT_ARTIFACT = "ginkgo-report"
BACKPORT_BRANCH = "backport/"


class GateError(Exception):
    """An input the gate cannot act on safely."""


def parse_marker(body):
    """Return (verdict, {class: count}, head) from a panel review body, or None."""
    match = MARKER.search(body or "")
    if not match:
        return None
    verdict = match.group("verdict")
    if verdict not in CONCLUSION:
        raise GateError(f"unknown qa-review verdict {verdict!r}")
    classes = {}
    for item in filter(None, match.group("classes").split(",")):
        key, _, count = item.partition(":")
        if key not in CLASS_WORDS or not count.isdigit():
            raise GateError(f"malformed classes in qa-review marker: {item!r}")
        classes[key] = int(count)
    return verdict, classes, match.group("head")


def class_summary(classes):
    parts = [f"{classes[k]} {CLASS_WORDS[k]}" for k in "abcd" if classes.get(k)]
    return ", ".join(parts) if parts else "no blocking classes"


def is_backport(pr, bot_login):
    """An automated backport: opened by the bot from a backport/ branch."""
    return ((pr.get("user") or {}).get("login") == bot_login
            and ((pr.get("head") or {}).get("ref") or "").startswith(BACKPORT_BRANCH))


def unescape_go(text):
    r"""The spec text as Go reads the string literal: \" -> ", \\ -> \, \n -> newline."""
    return re.sub(r"\\(.)", lambda m: GO_ESCAPES.get(m.group(1), m.group(1)), text)


def backport_checks(pr, check_name):
    head = (pr.get("head") or {}).get("sha", "")
    summary = ("Automated backport: the original PR was reviewed on main, so the QA review is "
               f"skipped here.\n\nPR: {pr.get('html_url', '')}")
    return [{"name": check_name, "head_sha": head, "conclusion": "success",
             "title": "QA review: automated backport, skipped", "summary": summary},
            {"name": f"{check_name}-ci", "head_sha": head, "conclusion": "success",
             "title": "QA review: automated backport, CI spec check skipped", "summary": summary}]


def decide_backport(event, bot_login, check_name):
    """Map a pull_request event to the two green check-runs, or to a skip."""
    pr = event.get("pull_request") or {}
    if not is_backport(pr, bot_login):
        return {"skip": f"PR by {(pr.get('user') or {}).get('login') or 'unknown'} is not an automated backport"}
    pusher = (event.get("sender") or {}).get("login", "")
    if pusher != bot_login:
        return {"skip": f"{pusher or 'unknown'} pushed to the backport; the panel reviews this head"}
    return {"checks": backport_checks(pr, check_name), "request_qa_review": False,
            "pr_number": pr.get("number")}


def decide_review(event, panel_login, check_name):
    """Map a submitted review to a check-run request, or to a skip with a reason."""
    review = event.get("review") or {}
    author = (review.get("user") or {}).get("login", "")
    if author != panel_login:
        return {"skip": f"review by {author or 'unknown'}, not the panel ({panel_login})"}
    pr = event.get("pull_request") or {}
    parsed = parse_marker(review.get("body"))
    if parsed is None:
        return {"skip": "panel review carries no qa-review marker"}
    verdict, classes, head = parsed
    current = (pr.get("head") or {}).get("sha", "")
    if head != current:
        return {"skip": f"marker is for {head[:7]}, PR head is {current[:7] or 'unknown'}"}
    title = {
        "block": f"QA review: blocked ({class_summary(classes)})",
        "pass": "QA review: passed",
        "needs_human": "QA review: a QA engineer decides",
        "not_run": "QA review: panel did not run the QA lanes; re-run it or a QA engineer decides",
    }[verdict]
    summary = (f"Verdict `{verdict}` from the review panel.\n\nClasses: {class_summary(classes)}."
               f"\n\nReview: {review.get('html_url', '')}\n\n"
               "A QA engineer can override with `/qa-review override <reason>` or ask for a "
               "person with `/qa-review human`.")
    return {
        "check": {"name": check_name, "head_sha": head, "conclusion": CONCLUSION[verdict],
                  "title": title, "summary": summary},
        "request_qa_review": verdict == "needs_human",
        "pr_number": pr.get("number"),
    }


def decide_comment(event, qa_logins, check_name, command="/qa-review"):
    """Map a PR comment to an override, a human request, or a skip."""
    issue = event.get("issue") or {}
    if not issue.get("pull_request"):
        return {"skip": "comment is not on a pull request"}
    comment = event.get("comment") or {}
    first_line = (comment.get("body") or "").strip().splitlines()[:1]
    words = first_line[0].split() if first_line else []
    if len(words) < 2 or words[0] != command:
        return {"skip": "comment does not open with the command"}
    author = (comment.get("user") or {}).get("login", "")
    verb = words[1]
    if verb == "override":
        if author not in qa_logins:
            return {"skip": f"{author or 'unknown'} is not a QA login; override ignored"}
        reason = " ".join(words[2:]).strip()
        if not reason:
            return {"skip": "override needs a reason: /qa-review override <reason>"}
        summary = (f"@{author} overrode the panel verdict: {reason}\n\n"
                   f"Comment: {comment.get('html_url', '')}")
        return {
            "checks": [{"name": check_name, "head_sha": None, "conclusion": "success",
                        "title": f"QA review: overridden by @{author}", "summary": summary},
                       {"name": f"{check_name}-ci", "head_sha": None, "conclusion": "success",
                        "title": f"QA review: CI spec check overridden by @{author}",
                        "summary": summary}],
            "request_qa_review": False,
            "pr_number": issue.get("number"),
            "comment_at": comment.get("created_at", ""),
        }
    if verb == "human":
        if comment.get("author_association") not in MEMBER_ASSOCIATIONS:
            return {"skip": f"{author or 'unknown'} may not ask for a QA review here"}
        return {
            "check": {"name": check_name, "head_sha": None, "conclusion": "action_required",
                      "title": "QA review: a QA engineer decides",
                      "summary": f"@{author} asked for a person.\n\nComment: "
                                 f"{comment.get('html_url', '')}"},
            "request_qa_review": True,
            "pr_number": issue.get("number"),
            "comment_at": comment.get("created_at", ""),
        }
    return {"skip": f"unknown {command} verb {verb!r}; use override <reason> or human"}


def added_specs(diff):
    """Spec texts the diff adds in e2e Go files: `It("...")` on an added line."""
    specs, in_e2e_go = [], False
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[4:].removeprefix("b/")
            in_e2e_go = path.endswith(".go") and ("/e2e" in f"/{path}")
        elif in_e2e_go:
            match = ADDED_SPEC.match(line)
            if match:
                specs.append(unescape_go(match.group(1)))
    return specs


def merge_state(states, text, state):
    """Keep the worst state seen for a spec text (same It text in two containers or reports)."""
    rank = STATE_RANK.get(state, STATE_RANK["failed"])
    if text not in states or rank > STATE_RANK.get(states[text], STATE_RANK["failed"]):
        states[text] = state


def report_specs(report, states=None):
    """{spec text: state} for every leaf spec in a Ginkgo JSON report (a list of suites)."""
    states = {} if states is None else states
    for suite in report:
        for spec in suite.get("SpecReports") or []:
            if spec.get("LeafNodeType") in ("It", "Specify", None):
                merge_state(states, spec.get("LeafNodeText", ""), spec.get("State", ""))
    return states


def decide_ci(run, pr_number, added, states, check_name):
    """Compare the PR's new specs with what the e2e run reported."""
    if run.get("conclusion") not in ("success", "failure"):
        return {"skip": f"e2e run ended {run.get('conclusion') or 'unknown'}, nothing to compare"}
    if not added:
        return {"skip": "the PR adds no e2e spec"}
    missing = [t for t in added if t not in states]
    not_passed = [f"{t} ({states[t]})" for t in added if t in states and states[t] != "passed"]
    head = run.get("head_sha", "")
    if missing or not_passed:
        lines = [f"- did not run: {t}" for t in missing] + [f"- {t}" for t in not_passed]
        title = f"QA review: {len(missing) + len(not_passed)} new spec(s) did not run or pass in CI"
        summary = ("New specs this PR adds, checked against the Ginkgo report of "
                   f"{run.get('html_url', '')}:\n\n" + "\n".join(lines) +
                   "\n\nA spec the PR label filter never selects, or a focused/skipped spec, "
                   "lands here. Fix the filter or the spec and push.")
        conclusion = "failure"
    else:
        title = f"QA review: all {len(added)} new spec(s) ran and passed in CI"
        summary = f"Ginkgo report: {run.get('html_url', '')}"
        conclusion = "success"
    return {
        "check": {"name": f"{check_name}-ci", "head_sha": head, "conclusion": conclusion,
                  "title": title, "summary": summary},
        "request_qa_review": False,
        "pr_number": pr_number,
    }


def gh(args, token, **kwargs):
    env = {**os.environ, "GH_TOKEN": token}
    result = subprocess.run(["gh", *args], capture_output=True, text=True, env=env, check=False,
                            **kwargs)
    if result.returncode:
        raise GateError(f"gh {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def run_pr_number(run, repo, token):
    """The open PR an e2e run belongs to. A /test-e2e run is a workflow_dispatch on the PR's
    head branch, so `pull_requests` is empty and the head commit names the PR instead."""
    prs = run.get("pull_requests") or []
    if prs:
        return prs[0]["number"]
    head = run.get("head_sha") or ""
    if not head:
        return None
    for pr in gh_api([f"repos/{repo}/commits/{head}/pulls"], token) or []:
        if pr.get("state") == "open":
            return pr["number"]
    return None


def pr_diff(repo, pr_number, token):
    """A diff of the PR built from the files API (patch per file, up to 3000 files), in the
    `+++ b/<path>` shape added_specs reads. `gh pr diff` refuses PRs over the diff limit."""
    files = gh_api([f"repos/{repo}/pulls/{pr_number}/files", "--paginate", "--slurp"], token)
    return "\n".join(f"+++ b/{f['filename']}\n{f.get('patch') or ''}"
                      for page in files for f in page)


def collect_ci(event, repo, token, check_name):
    """Fetch the diff and the Ginkgo report for a finished e2e run, then decide."""
    run = event.get("workflow_run") or {}
    pr_number = run_pr_number(run, repo, token)
    if pr_number is None:
        return {"skip": "e2e run is not for an open pull request"}
    try:
        added = added_specs(pr_diff(repo, pr_number, token))
    except GateError as error:
        return {"check": {"name": f"{check_name}-ci", "head_sha": run.get("head_sha", ""),
                          "conclusion": "action_required",
                          "title": "QA review: PR diff unavailable, a QA engineer checks the new specs",
                          "summary": f"{error}\n\nOverride with `/qa-review override <reason>`."},
                "request_qa_review": False, "pr_number": pr_number}
    if not added:
        return {"skip": "the PR adds no e2e spec"}
    with tempfile.TemporaryDirectory() as tmp:
        try:
            gh(["run", "download", str(run["id"]), "-R", repo, "-n", REPORT_ARTIFACT, "-D", tmp], token)
        except GateError:
            return {"skip": f"e2e run uploaded no {REPORT_ARTIFACT} artifact"}
        states = {}
        for path in sorted(glob.glob(os.path.join(tmp, "**", "*.json"), recursive=True)):
            with open(path, encoding="utf-8") as fh:
                report_specs(json.load(fh), states)
    return decide_ci(run, pr_number, added, states, check_name)


def gh_api(args, token, payload=None):
    command = ["gh", "api", *args]
    env = {**os.environ, "GH_TOKEN": token}
    stdin = None
    if payload is not None:
        command += ["--input", "-"]
        stdin = json.dumps(payload)
    result = subprocess.run(command, input=stdin, capture_output=True, text=True, env=env,
                            check=False)
    if result.returncode:
        raise GateError(f"gh api {' '.join(args)} failed: {result.stderr.strip()}")
    return json.loads(result.stdout) if result.stdout.strip() else {}


def comment_head(decision, repo, token):
    """The PR head a /qa-review comment applies to, or None when the author pushed after the
    comment: a decision made on one head must not land on a commit nobody looked at."""
    pr_number = decision["pr_number"]
    head = gh_api([f"repos/{repo}/pulls/{pr_number}"], token)["head"]["sha"]
    commits = gh_api([f"repos/{repo}/pulls/{pr_number}/commits", "--paginate", "--slurp"], token)
    pushed = max((c.get("commit", {}).get("committer", {}).get("date", "")
                  for page in commits for c in page), default="")
    if decision.get("comment_at") and pushed > decision["comment_at"]:
        return None
    return head


def apply(decision, repo, token, qa_team, run_url):
    """Create the check-run(s) and, when asked, request the QA team's review. Returns the
    head the checks landed on, or None when the comment is stale."""
    checks = decision.get("checks") or [decision["check"]]
    head = checks[0]["head_sha"]
    if head is None:
        head = comment_head(decision, repo, token)
        if head is None:
            print("::notice::qa-review-gate: the PR changed after the comment; comment again on the new head")
            return None
    for check in checks:
        gh_api([f"repos/{repo}/check-runs", "-X", "POST"], token, {
            "name": check["name"], "head_sha": head, "status": "completed",
            "conclusion": check["conclusion"], "details_url": run_url,
            "output": {"title": check["title"], "summary": check["summary"]},
        })
    if decision["request_qa_review"] and qa_team:
        org, _, slug = qa_team.partition("/")
        try:
            gh_api([f"repos/{repo}/pulls/{decision['pr_number']}/requested_reviewers", "-X", "POST"],
                   token, {"team_reviewers": [slug or org]})
        except GateError as error:
            # The check-run is already up; a token that cannot name the team must not fail the job.
            print(f"::warning::qa-review-gate: could not request {qa_team}: {error}")
    return head


def main():
    mode = os.environ.get("INPUT_MODE", "")
    check_name = os.environ.get("INPUT_CHECK_NAME", "qa-review")
    panel_login = os.environ.get("INPUT_PANEL_LOGIN", "loft-bot")
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as fh:
        event = json.load(fh)
    if mode == "review":
        decision = decide_review(event, panel_login, check_name)
    elif mode == "comment":
        logins = {s.strip() for s in os.environ.get("INPUT_QA_LOGINS", "").split(",") if s.strip()}
        decision = decide_comment(event, logins, check_name)
    elif mode == "ci":
        decision = collect_ci(event, os.environ["GITHUB_REPOSITORY"],
                              os.environ["INPUT_GITHUB_TOKEN"], check_name)
    elif mode == "backport":
        decision = decide_backport(event, panel_login, check_name)
    else:
        raise GateError(f"INPUT_MODE must be review, comment, ci or backport, got {mode!r}")
    if "skip" in decision:
        print(f"::notice::qa-review-gate: {decision['skip']}")
        return 0
    head = apply(decision, os.environ["GITHUB_REPOSITORY"], os.environ["INPUT_GITHUB_TOKEN"],
                 os.environ.get("INPUT_QA_TEAM", ""), os.environ.get("INPUT_RUN_URL", ""))
    for check in decision.get("checks") or [decision["check"]] if head else []:
        print(f"qa-review-gate: {check['name']} -> {check['conclusion']} on {head[:7]}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GateError as error:
        print(f"::error::qa-review-gate: {error}")
        sys.exit(1)

"""Turn the review panel's verdict, or a QA override comment, into the qa-review check-run.

Two event shapes, both read from GITHUB_EVENT_PATH:

- pull_request_review (submitted): the panel bot's review body ends with a marker line
  `<!-- qa-review verdict=<v> classes=a:N,b:N,c:N,d:N head=<sha> -->`. The verdict becomes the
  check-run conclusion on that head. A review from anyone else, or a marker for another head,
  is ignored.
- issue_comment (created): `/qa-review override <reason>` from a QA login completes the
  check-run as success and records who overrode it. `/qa-review human` from a repository
  member asks the QA team for a review and leaves the check-run waiting for a person.

Every decision is a plain dict so the tests never touch the network; `apply` is the only
function that calls `gh`.
"""

import json
import os
import re
import subprocess
import sys

MARKER = re.compile(
    r"<!--\s*qa-review\s+verdict=(?P<verdict>[a-z_]+)\s+classes=(?P<classes>\S*)"
    r"\s+head=(?P<head>[0-9a-f]{40})\s*-->"
)
CONCLUSION = {"block": "failure", "pass": "success", "needs_human": "action_required",
              "not_run": "neutral"}
CLASS_WORDS = {"a": "need a test", "b": "weak test", "c": "no test", "d": "product gap"}
MEMBER_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}


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


def decide_review(event, panel_login, check_name):
    """Map a submitted review to a check-run request, or to a skip with a reason."""
    review = event.get("review") or {}
    author = (review.get("user") or {}).get("login", "")
    if author != panel_login:
        return {"skip": f"review by {author or 'unknown'}, not the panel ({panel_login})"}
    parsed = parse_marker(review.get("body"))
    if parsed is None:
        return {"skip": "panel review carries no qa-review marker"}
    verdict, classes, head = parsed
    pr = event.get("pull_request") or {}
    current = (pr.get("head") or {}).get("sha", "")
    if head != current:
        return {"skip": f"marker is for {head[:7]}, PR head is {current[:7] or 'unknown'}"}
    title = {
        "block": f"QA review: blocked ({class_summary(classes)})",
        "pass": "QA review: passed",
        "needs_human": "QA review: a QA engineer decides",
        "not_run": "QA review: panel did not run the QA lanes",
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
        return {
            "check": {"name": check_name, "head_sha": None, "conclusion": "success",
                      "title": f"QA review: overridden by @{author}",
                      "summary": f"@{author} overrode the panel verdict: {reason}\n\n"
                                 f"Comment: {comment.get('html_url', '')}"},
            "request_qa_review": False,
            "pr_number": issue.get("number"),
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
        }
    return {"skip": f"unknown {command} verb {verb!r}; use override <reason> or human"}


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


def apply(decision, repo, token, qa_team, run_url):
    """Create the check-run and, when asked, request the QA team's review."""
    check = decision["check"]
    head = check["head_sha"]
    if head is None:
        pr = gh_api([f"repos/{repo}/pulls/{decision['pr_number']}"], token)
        head = pr["head"]["sha"]
    gh_api([f"repos/{repo}/check-runs", "-X", "POST"], token, {
        "name": check["name"], "head_sha": head, "status": "completed",
        "conclusion": check["conclusion"], "details_url": run_url,
        "output": {"title": check["title"], "summary": check["summary"]},
    })
    if decision["request_qa_review"] and qa_team:
        org, _, slug = qa_team.partition("/")
        gh_api([f"repos/{repo}/pulls/{decision['pr_number']}/requested_reviewers", "-X", "POST"],
               token, {"team_reviewers": [slug or org]})
    return head


def main():
    mode = os.environ.get("INPUT_MODE", "")
    check_name = os.environ.get("INPUT_CHECK_NAME", "qa-review")
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as fh:
        event = json.load(fh)
    if mode == "review":
        decision = decide_review(event, os.environ.get("INPUT_PANEL_LOGIN", "loft-bot"), check_name)
    elif mode == "comment":
        logins = {s.strip() for s in os.environ.get("INPUT_QA_LOGINS", "").split(",") if s.strip()}
        decision = decide_comment(event, logins, check_name)
    else:
        raise GateError(f"INPUT_MODE must be review or comment, got {mode!r}")
    if "skip" in decision:
        print(f"::notice::qa-review-gate: {decision['skip']}")
        return 0
    head = apply(decision, os.environ["GITHUB_REPOSITORY"], os.environ["INPUT_GITHUB_TOKEN"],
                 os.environ.get("INPUT_QA_TEAM", ""), os.environ.get("INPUT_RUN_URL", ""))
    print(f"qa-review-gate: {check_name} -> {decision['check']['conclusion']} on {head[:7]}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GateError as error:
        print(f"::error::qa-review-gate: {error}")
        sys.exit(1)

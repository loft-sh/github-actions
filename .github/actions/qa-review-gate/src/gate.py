"""Turn the review panel's verdict, or an override comment, into the qa-review check-run.

Event shapes, all read from GITHUB_EVENT_PATH:

- pull_request_review (submitted): the panel bot's review body ends with a marker line
  `<!-- qa-review verdict=<v> classes=a:N,b:N,c:N,d:N head=<sha> -->`. The verdict becomes the
  `qa-review` check-run conclusion on that head. A review from anyone else, or a marker for
  another head, is ignored. `needs_human` hands the PR back to its author (assignee), who
  answers the panel or tags QA. The same event also opens the `qa-test-run` check-run on that
  head: success when the PR adds no e2e spec, otherwise action_required until an e2e run
  reports (so the check can be required without blocking spec-free PRs). A `qa-test-run`
  already on the head is left alone.
- issue_comment (created): `/qa-review override [<reason>]` from an override login or a member
  of an override team (tech leads, QA; team membership is read with `org-token`, a token with
  `read:org`, since GITHUB_TOKEN cannot) completes both check-runs as success and records who
  overrode them. The override binds to the
  panel verdict it answers: the PR's current head must carry a panel marker submitted before
  the comment, otherwise the gate does nothing and asks for a fresh comment. When the panel
  never posted on that head (an outage), `/qa-review override <sha> [<reason>]` names the head
  instead and lands only while that sha is still the PR head. `/qa-review human` from a
  repository member asks the QA team for a review and leaves `qa-review` waiting for a person.
- workflow_run (completed) of the e2e workflow: every `It(`, `Specify(` or `Entry(` the PR
  adds is looked up by file and line in the Ginkgo JSON report the run uploaded. A new spec
  that did not run, or did not pass, turns `qa-test-run` red. The diff is the compare of the
  PR base with the run's own head, so it describes the commits the run tested. A run whose head
  is no longer the PR head is superseded and ignored; a finished run without a report asks a
  person. `qa-review` is never touched.
- pull_request (opened) by a trusted bot: an automated backport (`loft-bot`, `backport/`) was
  reviewed on main; a flake-fixer PR (`vcluster-qa-bot[bot]`, `flake-fixer/`) ran the QA review
  itself. On the head the bot opened the PR with, both check-runs complete as success at once,
  so the repo's auto-approve workflow can approve it. Any later head, whoever pushed it, gets no
  free pass: it has no check-run until the panel reviews it and the e2e run reports. (A bot
  backport keeps the original author on its commits, so authorship cannot tell a bot push from
  a person's.)

Every decision is a plain dict so the tests never touch the network; `apply` is the only
function that creates check-runs.
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
ADDED_SPEC = re.compile(r'^\+[^+].*\b[FPX]?(?:It|Specify|Entry)\(\s*"((?:[^"\\]|\\.)+)"')
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)")
GO_ESCAPES = {"n": "\n", "t": "\t", "r": "\r"}
# Ginkgo states, worst last; two reports for one spec keep the worst.
STATE_RANK = {"passed": 0, "": 1, "pending": 2, "skipped": 3, "timedout": 4, "interrupted": 4,
              "aborted": 4, "panicked": 5, "failed": 5}
REPORT_ARTIFACT = "ginkgo-report"
SHA_PREFIX = re.compile(r"^[0-9a-f]{7,40}$")
COMPARE_FILE_CAP = 300  # the compare API lists at most this many files and says nothing when it cuts
DEFAULT_BOTS = "loft-bot:backport/,vcluster-qa-bot[bot]:flake-fixer/"
OVERRIDE_HINT = ("Override with `/qa-review override [<reason>]` (`/qa-review override <sha> "
                 "[<reason>]` when the panel has not posted on this head).")


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


def parse_bots(text):
    """{login: branch prefix} from `login:prefix,login:prefix`."""
    bots = {}
    for item in filter(None, (s.strip() for s in (text or "").split(","))):
        login, sep, prefix = item.partition(":")
        if not sep or not login or not prefix:
            raise GateError(f"bot-prs entry must be login:branch-prefix, got {item!r}")
        bots[login] = prefix
    return bots


def bot_pr(pr, bots):
    """The trusted bot that opened this PR from its branch prefix, or None."""
    login = (pr.get("user") or {}).get("login")
    ref = (pr.get("head") or {}).get("ref") or ""
    return login if login in bots and ref.startswith(bots[login]) else None


def unescape_go(text):
    r"""The spec text as Go reads the string literal: \" -> ", \\ -> \, \n -> newline."""
    return re.sub(r"\\(.)", lambda m: GO_ESCAPES.get(m.group(1), m.group(1)), text)


def bot_checks(pr, login, check_name, test_check):
    head = (pr.get("head") or {}).get("sha", "")
    summary = (f"PR opened by {login}: reviewed before it was opened, so the QA review is "
               f"skipped here.\n\nPR: {pr.get('html_url', '')}")
    return [{"name": check_name, "head_sha": head, "conclusion": "success",
             "title": f"QA review: {login} PR, skipped", "summary": summary},
            {"name": test_check, "head_sha": head, "conclusion": "success",
             "title": f"QA test run: {login} PR, skipped", "summary": summary}]


def decide_bot(event, bots, check_name, test_check="qa-test-run"):
    """Map a pull_request event to the two green check-runs, or to a skip."""
    pr = event.get("pull_request") or {}
    login = bot_pr(pr, bots)
    if login is None:
        return {"skip": f"PR by {(pr.get('user') or {}).get('login') or 'unknown'} is not a trusted bot PR"}
    pusher = (event.get("sender") or {}).get("login", "")
    if event.get("action") != "opened" or pusher != login:
        return {"skip": "only the head the bot opened the PR with passes; the panel reviews this head"}
    return {"checks": bot_checks(pr, login, check_name, test_check), "request_qa_review": False,
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
        "needs_human": "QA review: the author answers the panel; tag QA with /qa-review human if needed",
        "not_run": "QA review: panel did not run the QA lanes; re-run it or ask for an override",
    }[verdict]
    summary = (f"Verdict `{verdict}` from the review panel.\n\nClasses: {class_summary(classes)}."
               f"\n\nReview: {review.get('html_url', '')}\n\n{OVERRIDE_HINT} "
               "Ask for a person with `/qa-review human`.")
    return {
        "check": {"name": check_name, "head_sha": head, "conclusion": CONCLUSION[verdict],
                  "title": title, "summary": summary},
        "request_qa_review": False,
        "assign_author": verdict == "needs_human",
        "pr_number": pr.get("number"),
        "base_ref": (pr.get("base") or {}).get("ref", ""),
    }


def test_run_pending(added, head, pr_number, test_check, run_hint="/test-e2e"):
    """The `qa-test-run` check-run opened with the panel verdict: green when the PR adds no spec,
    otherwise waiting for an e2e run; `collect_ci` overwrites it with the run's result."""
    if not added:
        return {"check": {"name": test_check, "head_sha": head, "conclusion": "success",
                          "title": "QA test run: the PR adds no e2e spec",
                          "summary": "Nothing to run for this PR."},
                "request_qa_review": False, "pr_number": pr_number}
    lines = "\n".join(f"- {s['path']}:{s['line']} {s['text']}" for s in added)
    return {"check": {"name": test_check, "head_sha": head, "conclusion": "action_required",
                      "title": f"QA test run: {len(added)} new spec(s) wait for `{run_hint}`",
                      "summary": f"New specs this PR adds:\n\n{lines}\n\nRun `{run_hint}`; the "
                                 f"check turns green when they ran and passed. {OVERRIDE_HINT}"},
            "request_qa_review": False, "pr_number": pr_number}


def collect_review(event, repo, token, panel_login, check_name, test_check="qa-test-run"):
    """The verdict check-run plus, when no `qa-test-run` exists on the head yet, its opener."""
    decision = decide_review(event, panel_login, check_name)
    if "skip" in decision:
        return decision
    head = decision["check"]["head_sha"]
    pr_number = decision["pr_number"]
    existing = gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={test_check}"], token)
    if existing.get("check_runs"):
        return decision
    try:
        added = added_specs(pr_diff(repo, decision["base_ref"], head, token))
        opener = test_run_pending(added, head, pr_number, test_check)
    except GateError as error:
        opener = ask_person(test_check, head, pr_number,
                            "QA test run: PR diff unavailable, a person checks the new specs",
                            str(error))
    decision["checks"] = [decision.pop("check"), opener["check"]]
    return decision


def decide_comment(event, override_logins, check_name, test_check="qa-test-run", command="/qa-review",
                   member=lambda login: False):
    """Map a PR comment to an override, a human request, or a skip. `member(login)` says
    whether a login outside `override_logins` belongs to an override team."""
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
        if author not in override_logins and not member(author):
            return {"skip": f"{author or 'unknown'} is not an override login or team member; override ignored"}
        rest = words[2:]
        sha_prefix = rest.pop(0) if rest and SHA_PREFIX.match(rest[0]) else None
        reason = " ".join(rest).strip() or "no reason given"
        summary = (f"@{author} overrode the panel verdict: {reason}\n\n"
                   f"Comment: {comment.get('html_url', '')}")
        return {
            "checks": [{"name": check_name, "head_sha": None, "conclusion": "success",
                        "title": f"QA review: overridden by @{author}", "summary": summary},
                       {"name": test_check, "head_sha": None, "conclusion": "success",
                        "title": f"QA test run: overridden by @{author}", "summary": summary}],
            "request_qa_review": False,
            "pr_number": issue.get("number"),
            "comment_at": comment.get("created_at", ""),
            "binds_to_marker": True,
            "sha_prefix": sha_prefix,
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
    return {"skip": f"unknown {command} verb {verb!r}; use override [<reason>] or human"}


def added_specs(diff):
    """Specs the diff adds in e2e Go files, as {path, line, text}: an `It("...")`,
    `Specify("...")` or table `Entry("...")` on an added line, with its line in the new file."""
    specs, in_e2e_go, path, line = [], False, "", 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[4:].removeprefix("b/")
            in_e2e_go = path.endswith(".go") and ("/e2e" in f"/{path}")
            continue
        hunk = HUNK.match(raw)
        if hunk:
            line = int(hunk.group(1))
            continue
        if raw.startswith("-") or raw.startswith("\\"):
            continue
        if in_e2e_go and raw.startswith("+"):
            match = ADDED_SPEC.match(raw)
            if match:
                specs.append({"path": path, "line": line, "text": unescape_go(match.group(1))})
        line += 1
    return specs


def merge_state(states, key, state):
    """Keep the worst state seen for a spec location (the same spec in two reports)."""
    rank = STATE_RANK.get(state, STATE_RANK["failed"])
    if key not in states or rank > STATE_RANK.get(states[key], STATE_RANK["failed"]):
        states[key] = state


def report_specs(report, states=None):
    """{(file, line): state} for every leaf spec in a Ginkgo JSON report (a list of suites).
    The file is the runner's absolute path; spec_state matches it by suffix."""
    states = {} if states is None else states
    for suite in report:
        for spec in suite.get("SpecReports") or []:
            if spec.get("LeafNodeType") in ("It", "Specify", None):
                loc = spec.get("LeafNodeLocation") or {}
                merge_state(states, (loc.get("FileName", ""), loc.get("LineNumber", 0)),
                            spec.get("State", ""))
    return states


def spec_state(states, spec):
    """The reported state of the spec declared at spec["path"]:spec["line"], or None."""
    for (file, line), state in states.items():
        if line == spec["line"] and (file == spec["path"] or file.endswith("/" + spec["path"])):
            return state
    return None


def decide_ci(run, pr_number, added, states, test_check="qa-test-run"):
    """Compare the PR's new specs with what the e2e run reported."""
    if run.get("conclusion") not in ("success", "failure"):
        return {"skip": f"e2e run ended {run.get('conclusion') or 'unknown'}, nothing to compare"}
    if not added:
        return {"skip": "the PR adds no e2e spec"}
    graded = [(f"{s['path']}:{s['line']} {s['text']}", spec_state(states, s)) for s in added]
    missing = [label for label, state in graded if state is None]
    not_passed = [f"{label} ({state})" for label, state in graded if state not in (None, "passed")]
    head = run.get("head_sha", "")
    if missing or not_passed:
        lines = [f"- did not run: {t}" for t in missing] + [f"- {t}" for t in not_passed]
        title = f"QA test run: {len(missing) + len(not_passed)} new spec(s) did not run or pass"
        summary = ("New specs this PR adds, checked against the Ginkgo report of "
                   f"{run.get('html_url', '')}:\n\n" + "\n".join(lines) +
                   "\n\nA spec the PR label filter never selects, or a focused/skipped spec, "
                   "lands here. Fix the filter or the spec and push.")
        conclusion = "failure"
    else:
        title = f"QA test run: all {len(added)} new spec(s) ran and passed"
        summary = f"Ginkgo report: {run.get('html_url', '')}"
        conclusion = "success"
    return {
        "check": {"name": test_check, "head_sha": head, "conclusion": conclusion,
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


def pr_diff(repo, base_ref, head_sha, token):
    """The diff of the commits an e2e run tested: the PR base compared with the run's head
    (three dots, so from the merge base), in the `+++ b/<path>` shape added_specs reads."""
    files = gh_api([f"repos/{repo}/compare/{base_ref}...{head_sha}"], token).get("files") or []
    if len(files) >= COMPARE_FILE_CAP:
        raise GateError(f"compare lists {COMPARE_FILE_CAP} files; the diff may be cut")
    return "\n".join(f"+++ b/{f['filename']}\n{f.get('patch') or ''}" for f in files)


def ask_person(test_check, head, pr_number, title, detail):
    """A `qa-test-run` check-run nobody can grade automatically: a person decides."""
    return {"check": {"name": test_check, "head_sha": head, "conclusion": "action_required",
                      "title": title,
                      "summary": f"{detail}\n\nRe-run `/test-e2e`, or ask for an override. {OVERRIDE_HINT}"},
            "request_qa_review": False, "pr_number": pr_number}


def collect_ci(event, repo, token, test_check="qa-test-run"):
    """Fetch the diff and the Ginkgo report for a finished e2e run, then decide."""
    run = event.get("workflow_run") or {}
    head = run.get("head_sha", "")
    if run.get("conclusion") not in ("success", "failure"):
        return {"skip": f"e2e run ended {run.get('conclusion') or 'unknown'}, nothing to compare"}
    pr_number = run_pr_number(run, repo, token)
    if pr_number is None:
        return {"skip": "e2e run is not for an open pull request"}
    try:
        pr = gh_api([f"repos/{repo}/pulls/{pr_number}"], token)
        current = pr["head"]["sha"]
        if current != head:
            return {"skip": f"e2e run is for {head[:7]}, PR head is {current[:7]}; superseded"}
        added = added_specs(pr_diff(repo, pr["base"]["ref"], head, token))
    except GateError as error:
        return ask_person(test_check, head, pr_number,
                          "QA test run: PR diff unavailable, a person checks the new specs",
                          str(error))
    if not added:
        return {"skip": "the PR adds no e2e spec"}
    with tempfile.TemporaryDirectory() as tmp:
        try:
            gh(["run", "download", str(run["id"]), "-R", repo, "-n", REPORT_ARTIFACT, "-D", tmp], token)
        except GateError as error:
            return ask_person(test_check, head, pr_number,
                              f"QA test run: no {REPORT_ARTIFACT} for {len(added)} new spec(s), "
                              "a person checks them", str(error))
        states = {}
        for path in sorted(glob.glob(os.path.join(tmp, "**", "*.json"), recursive=True)):
            with open(path, encoding="utf-8") as fh:
                report_specs(json.load(fh), states)
    return decide_ci(run, pr_number, added, states, test_check)


def team_member(login, teams, org_token):
    """Whether `login` is an active member of any `org/slug` in `teams`. Needs a token with
    read:org; without one the teams are ignored and the job says so."""
    if not teams or not login:
        return False
    if not org_token:
        print("::warning::qa-review-gate: override-teams set but no org-token; only override-logins apply")
        return False
    for team in teams:
        org, _, slug = team.partition("/")
        try:
            state = gh_api([f"orgs/{org}/teams/{slug}/memberships/{login}"], org_token).get("state")
        except GateError:
            continue  # 404: not a member
        if state == "active":
            return True
    return False


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


def comment_head(decision, repo, token, panel_login):
    """The PR head a /qa-review comment applies to. An override answers a panel verdict, so
    it lands only when the current head carries a panel marker submitted before the comment;
    a head pushed after the comment, or one the panel has not graded, returns None and the
    override login comments again on what they see."""
    pr_number = decision["pr_number"]
    head = gh_api([f"repos/{repo}/pulls/{pr_number}"], token)["head"]["sha"]
    if not decision.get("binds_to_marker"):
        return head
    if decision.get("sha_prefix"):
        return head if head.startswith(decision["sha_prefix"]) else None
    pages = gh_api([f"repos/{repo}/pulls/{pr_number}/reviews", "--paginate", "--slurp"], token)
    for review in (r for page in pages for r in page):
        if (review.get("user") or {}).get("login") != panel_login:
            continue
        try:
            parsed = parse_marker(review.get("body"))
        except GateError:
            continue
        if (parsed and parsed[2] == head
                and (review.get("submitted_at") or "") <= decision.get("comment_at", "")):
            return head
    return None


def apply(decision, repo, token, qa_team, run_url, panel_login="loft-bot"):
    """Create the check-run(s), hand the PR to its author or request the QA team when asked.
    Returns the head the checks landed on, or None when the comment binds to no verdict."""
    checks = decision.get("checks") or [decision["check"]]
    head = checks[0]["head_sha"]
    if head is None:
        head = comment_head(decision, repo, token, panel_login)
        if head is None:
            print("::notice::qa-review-gate: no panel verdict on the PR's current head before "
                  "the comment; wait for the panel, then comment again (or name the head: "
                  "/qa-review override <sha> [<reason>])")
            return None
    for check in checks:
        gh_api([f"repos/{repo}/check-runs", "-X", "POST"], token, {
            "name": check["name"], "head_sha": head, "status": "completed",
            "conclusion": check["conclusion"], "details_url": run_url,
            "output": {"title": check["title"], "summary": check["summary"]},
        })
    pr_number = decision["pr_number"]
    if decision.get("assign_author"):
        author = gh_api([f"repos/{repo}/pulls/{pr_number}"], token).get("user", {}).get("login")
        if author:
            try:
                gh_api([f"repos/{repo}/issues/{pr_number}/assignees", "-X", "POST"], token,
                       {"assignees": [author]})
            except GateError as error:
                print(f"::warning::qa-review-gate: could not assign @{author}: {error}")
    if decision["request_qa_review"] and qa_team:
        org, _, slug = qa_team.partition("/")
        try:
            gh_api([f"repos/{repo}/pulls/{pr_number}/requested_reviewers", "-X", "POST"],
                   token, {"team_reviewers": [slug or org]})
        except GateError as error:
            # The check-run is already up; a token that cannot name the team must not fail the job.
            print(f"::warning::qa-review-gate: could not request {qa_team}: {error}")
    return head


def main():
    mode = os.environ.get("INPUT_MODE", "")
    check_name = os.environ.get("INPUT_CHECK_NAME", "qa-review")
    test_check = os.environ.get("INPUT_TEST_CHECK_NAME", "qa-test-run")
    panel_login = os.environ.get("INPUT_PANEL_LOGIN", "loft-bot")
    repo, token = os.environ["GITHUB_REPOSITORY"], os.environ["INPUT_GITHUB_TOKEN"]
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as fh:
        event = json.load(fh)
    if mode == "review":
        decision = collect_review(event, repo, token, panel_login, check_name, test_check)
    elif mode == "comment":
        logins = {s.strip() for s in os.environ.get("INPUT_OVERRIDE_LOGINS", "").split(",") if s.strip()}
        teams = [s.strip() for s in os.environ.get("INPUT_OVERRIDE_TEAMS", "").split(",") if s.strip()]
        org_token = os.environ.get("INPUT_ORG_TOKEN", "")
        decision = decide_comment(event, logins, check_name, test_check,
                                  member=lambda login: team_member(login, teams, org_token))
    elif mode == "ci":
        decision = collect_ci(event, repo, token, test_check)
    elif mode == "bot":
        decision = decide_bot(event, parse_bots(os.environ.get("INPUT_BOT_PRS", DEFAULT_BOTS)),
                              check_name, test_check)
    else:
        raise GateError(f"INPUT_MODE must be review, comment, ci or bot, got {mode!r}")
    if "skip" in decision:
        print(f"::notice::qa-review-gate: {decision['skip']}")
        return 0
    head = apply(decision, repo, token, os.environ.get("INPUT_QA_TEAM", ""),
                 os.environ.get("INPUT_RUN_URL", ""), panel_login)
    for check in decision.get("checks") or [decision["check"]] if head else []:
        print(f"qa-review-gate: {check['name']} -> {check['conclusion']} on {head[:7]}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GateError as error:
        print(f"::error::qa-review-gate: {error}")
        sys.exit(1)

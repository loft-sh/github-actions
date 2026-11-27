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

from fnmatch import fnmatchcase
import glob
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
import zipfile

MARKER = re.compile(
    r"<!--\s*qa-review\s+verdict=(?P<verdict>[a-z_]+)\s+classes=(?P<classes>\S*)"
    r"\s+head=(?P<head>[0-9a-f]{40})\s+base=(?P<base>\S+)\s*-->"
)
RUN_BASE = re.compile(r"\bonto (\S+)")  # the e2e run title names the base its merge commit used
CONCLUSION = {"block": "failure", "pass": "success", "needs_human": "action_required",
              "not_run": "action_required"}
CLASS_WORDS = {"a": "need a test", "b": "weak test", "c": "no test", "d": "product gap"}
MEMBER_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
ADDED_SPEC = re.compile(r'^\+[^+].*\b[FPX]?(?:It|Specify|Entry)\s*\(\s*"((?:[^"\\]|\\.)*)"')
ADDED_DECLARATION = re.compile(r'^\+[^+].*\b[FPX]?(?:It|Specify|Entry|Describe|Context|When|DescribeTable)\s*\(')
LITERAL_DECLARATION = re.compile(r'^\+[^+].*\b[FPX]?(?:It|Specify|Entry|Describe|Context|When|DescribeTable)\s*\(\s*"(?:[^"\\]|\\.)*"')
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)")
GO_ESCAPES = {"n": "\n", "t": "\t", "r": "\r"}
# Ginkgo states, worst last; two reports for one spec keep the worst.
STATE_RANK = {"passed": 0, "": 1, "pending": 2, "skipped": 3, "timedout": 4, "interrupted": 4,
              "aborted": 4, "panicked": 5, "failed": 5}
REPORT_ARTIFACT = "ginkgo-report"
DEFAULT_TREES = f"{REPORT_ARTIFACT}="
TREES_EXTERNAL_ID = "qa-review-gate:trees:"
OPENER_EXTERNAL_ID = "qa-review-gate-provisional-opener"
BOT_EXTERNAL_ID = "qa-review-gate:bot"
OVERRIDE_EXTERNAL_ID = "qa-review-gate:override"
HUMAN_EXTERNAL_ID = "qa-review-gate:human"
VERDICT_EXTERNAL_ID = "qa-review-gate:verdict"
BASE_SEP = "^"  # never part of a git ref, so the base a run was graded against can follow it
# A /test-e2e dispatch run names the PR and the commit it tested in its run-name.
DISPATCH_TITLE = re.compile(r"#(\d+)\b.*\b([0-9a-f]{40})\b")
SHA_PREFIX = re.compile(r"^[0-9a-f]{7,40}$")
COMPARE_FILE_CAP = 300  # the compare API lists at most this many files and says nothing when it cuts
PR_FILES_CAP = 3000  # the PR files API stops here too
DEFAULT_BOTS = "loft-bot:backport/,vcluster-qa-bot[bot]:flake-fixer/"
# Mirrors the dispatcher's auto-review paths (slack-ai-bot config.py AutoReviewConfig.paths):
# a PR outside them never gets the panel, so the gate passes it as out of QA scope itself.
DEFAULT_QA_PATHS = "e2e*/**,staging/github.com/loft-sh/vcluster/e2e/**,.github/workflows/e2e*.yaml"
SCOPE_EXTERNAL_ID = "qa-review-gate:scope"
OVERRIDE_HINT = ("Override with `/qa-review override [<reason>]` (`/qa-review override <sha> "
                 "[<reason>]` when the panel has not posted on this head).")


class GateError(Exception):
    """An input the gate cannot act on safely."""


def parse_marker(body):
    """Return (verdict, {class: count}, head, base) from a panel review body, or None. The
    marker names the base the panel reviewed: the gate cannot tell otherwise whether a
    verdict posted after a retarget graded the old diff or the new one."""
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
    return verdict, classes, match.group("head"), match.group("base")


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


def bot_checks(pr, login, prefix, check_name, test_check):
    head = (pr.get("head") or {}).get("sha", "")
    # The panel (ai-agents lead, Phase 1.6) matches the backport title verbatim.
    what = "automated backport" if prefix == "backport/" else f"{login} PR"
    summary = (f"PR opened by {login}: reviewed before it was opened, so the QA review is "
               f"skipped here.\n\nPR: {pr.get('html_url', '')}")
    return [{"name": check_name, "head_sha": head, "conclusion": "success", "external_id": BOT_EXTERNAL_ID,
             "title": f"QA review: {what}, skipped", "summary": summary},
            {"name": test_check, "head_sha": head, "conclusion": "success", "external_id": BOT_EXTERNAL_ID,
             "title": f"QA test run: {what}, skipped", "summary": summary}]


def bot_passed(repo, sha, check_name, token):
    """True when this gate's bot mode already passed `sha` (the chain a bot push may extend)."""
    runs = from_actions(gh_api([f"repos/{repo}/commits/{sha}/check-runs?check_name={check_name}&filter=all&per_page=100"], token).get("check_runs"))
    return any(kind(r) == BOT_EXTERNAL_ID and r.get("conclusion") == "success" for r in runs)


def parse_paths(text):
    return [p.strip() for p in (text or "").split(",") if p.strip()]


def qa_owned(files, patterns):
    """The files under a QA-owned path, matched the way the dispatcher's `touches_e2e` does
    (slack-ai-bot auto_review.py): a star stays inside one path segment, a `**` segment spans
    any depth, and a vendored file never counts. The two must agree, or a PR gets no check."""
    def matches(parts, pattern):
        if not pattern:
            return not parts
        if pattern[0] == "**":
            if len(pattern) == 1:
                return bool(parts)
            return matches(parts, pattern[1:]) or bool(parts and matches(parts[1:], pattern))
        return bool(parts and fnmatchcase(parts[0], pattern[0]) and matches(parts[1:], pattern[1:]))

    return [f for f in files if "vendor" not in (parts := f.split("/"))
            and any(matches(parts, pattern.split("/")) for pattern in patterns)]


def changed_files(repo, base_sha, head_sha, token, number=None):
    """The files between the event's own base and head. The PR files endpoint would answer
    for the PR's current head, which a queued or rerun job must not grade the event SHA by;
    it is the fallback when the compare hits its cap, and only while the PR still sits on
    the event's own head and base, so it lists the same diff."""
    files = gh_api([f"repos/{repo}/compare/{base_sha}...{head_sha}"], token).get("files") or []
    if len(files) < COMPARE_FILE_CAP:
        return [f.get("filename", "") for f in files]
    def same_shas():
        pr = gh_api([f"repos/{repo}/pulls/{number}"], token) if number is not None else {}
        return ((pr.get("head") or {}).get("sha"), (pr.get("base") or {}).get("sha")) == (head_sha, base_sha), pr
    same, pr = same_shas()
    if not same:
        raise GateError(f"compare lists {COMPARE_FILE_CAP} files and the PR has moved on; the list may be cut")
    pages = gh_api([f"repos/{repo}/pulls/{number}/files?per_page=100", "--paginate", "--slurp"], token)
    names = [f.get("filename", "") for page in pages for f in page]
    # The PR files list stops at 3000 and a commit during pagination mixes two heads.
    if len(names) != pr.get("changed_files") or len(names) >= PR_FILES_CAP or not same_shas()[0]:
        raise GateError(f"the PR files list is cut ({len(names)} of {pr.get('changed_files')}) or the PR moved on")
    return names


def kind(run):
    """A run's external id without the base it was graded against. The gate before base
    tracking wrote an override and a request for a person with no external id: their titles
    name them, so a manual decision is never regraded as an unbased result."""
    external = (run.get("external_id") or "").partition(BASE_SEP)[0]
    if external:
        return external
    title = (run.get("output") or {}).get("title") or ""
    if ": overridden by @" in title:
        return OVERRIDE_EXTERNAL_ID
    return HUMAN_EXTERNAL_ID if title == "QA review: a QA engineer decides" else ""


def base_of(run):
    return (run.get("external_id") or "").partition(BASE_SEP)[2]


def with_base(external_id, base):
    return f"{external_id}{BASE_SEP}{base}" if base else external_id


def from_actions(runs):
    """Only the runs GitHub Actions published: the ruleset requires that source, and any app
    with checks: write could otherwise pass an override, a bot pass or a result off as ours."""
    return [run for run in runs or [] if (run.get("app") or {}).get("slug") == "github-actions"]


def scope_owned(runs):
    """True when the newest run is the scope check's own (a pass or a retarget placeholder),
    which the panel's decision or a regrade may replace; a verdict, result or override is not."""
    newest = max(runs, key=lambda run: run.get("id", 0), default=None)
    return bool(newest) and kind(newest) == SCOPE_EXTERNAL_ID


def scope_may_write(runs, base):
    """True when the scope check may write over the newest run of a check: no run yet, its
    own run, or a verdict, opener or e2e result graded against another base (a retarget) or
    recording none (written before the gate recorded it, so it may be for the old diff).
    An override, a bot pass, a request for a person, or a result for this base stays."""
    newest = max(runs, key=lambda run: run.get("id", 0), default=None)
    if not newest or kind(newest) == SCOPE_EXTERNAL_ID:
        return True
    if kind(newest) in (OVERRIDE_EXTERNAL_ID, BOT_EXTERNAL_ID, HUMAN_EXTERNAL_ID):
        return False
    return base_of(newest) != base


def scope_writable(repo, head, check_name, base, token):
    runs = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={check_name}&filter=all&per_page=100"], token).get("check_runs"))
    return scope_may_write(runs, base)


def current_base(repo, number, token):
    return ((gh_api([f"repos/{repo}/pulls/{number}"], token).get("base") or {}).get("ref", ""))


def decide_scope(event, repo, token, qa_paths, check_name, test_check="qa-test-run"):
    """Pass a PR that touches no QA-owned path: the panel never runs on it (the dispatcher
    triggers on these paths only), so a required check would block it for nothing. The verdict
    depends on the base, so a retarget (`edited` with a base change, same head) grades again
    and takes a pass back when the new diff is in scope."""
    pr = event.get("pull_request") or {}
    action = event.get("action")
    if action == "edited" and not (event.get("changes") or {}).get("base"):
        return {"skip": "pull_request edited: the base did not change"}
    if action not in ("opened", "synchronize", "reopened", "edited"):
        return {"skip": f"pull_request {action}: nothing to decide"}
    head = (pr.get("head") or {}).get("sha", "")
    base = (pr.get("base") or {}).get("sha", "")
    base_ref = (pr.get("base") or {}).get("ref", "")
    labels = {check_name: "QA review", test_check: "QA test run"}
    # Only the checks the scope check may write: a verdict, an e2e result or an override for
    # this base, a request for a person or a bot pass stays, whatever job order produced it;
    # a result graded against another base (a retarget) is replaced.
    names = [n for n in labels if scope_writable(repo, head, n, base_ref, token)]
    if not names:
        return {"skip": "the panel's verdict, a request for a person or an override owns both checks"}

    def placeholders(reason):
        return {"checks": [{"name": n, "head_sha": head, "conclusion": "action_required",
                            "external_id": SCOPE_EXTERNAL_ID,
                            "title": f"{labels[n]}: {reason} after retarget to {base_ref}, the panel decides",
                            "summary": f"After the retarget to {base_ref} the earlier out-of-scope pass no longer "
                                       f"applies ({reason}): comment /vcluster-review for the panel.\n\n"
                                       f"PR: {pr.get('html_url', '')}"} for n in names],
                "request_qa_review": False, "pr_number": pr.get("number"), "base_ref": base_ref}
    try:
        files = changed_files(repo, base, head, token, pr.get("number"))
    except GateError as error:
        if action == "edited":
            return placeholders("scope unknown")
        return {"skip": f"cannot list the changed files of {head[:7]} ({error}); the panel or an override decides"}
    owned = qa_owned(files, qa_paths)
    graded = f"base {base_ref}@{base[:7]}"
    if owned:
        if action != "edited":
            # Without a check the PR shows only "Expected", and nothing tells the author what to do.
            # A draft needs no comment when its author is one the dispatcher reviews by itself.
            how = "mark the PR ready or comment /vcluster-review" if pr.get("draft") else "comment /vcluster-review"
            checks = [{"name": n, "head_sha": head, "conclusion": "action_required",
                       "external_id": SCOPE_EXTERNAL_ID,
                       "title": f"{labels[n]}: waiting for the panel review, {how}",
                       "summary": f"{len(owned)} changed file(s) under a QA-owned path, so the review "
                                  "panel decides this check. It starts by itself when a PR opens or "
                                  "leaves draft. After a push it does not: comment `/vcluster-review` "
                                  "to get a review of this commit. If the panel does not start by "
                                  "itself (an author outside the organization), a repository member "
                                  f"comments `/vcluster-review`.\n\n{OVERRIDE_HINT}\n\n"
                                  f"PR: {pr.get('html_url', '')}"} for n in names if n != test_check]
            if test_check in names:
                # The test run waits for an e2e run, not for the panel: say which specs, or pass when there are none.
                try:
                    waits = test_run_pending(added_specs(pr_diff(repo, base_ref, head, token)), head,
                                             pr.get("number"), test_check)["check"]
                except GateError:
                    waits = {"name": test_check, "head_sha": head, "conclusion": "action_required",
                             "title": f"{labels[test_check]}: waiting for an e2e run of the new specs",
                             "summary": f"Run `/test-e2e <label-filter>` with a filter covering the new specs. {OVERRIDE_HINT}"}
                checks.append({**waits, "external_id": SCOPE_EXTERNAL_ID})
            return {"checks": checks, "request_qa_review": False, "pr_number": pr.get("number"), "base_ref": base_ref}
        return placeholders(f"{len(owned)} file(s) in scope")
    summary = (f"No changed file is under a QA-owned path ({', '.join(qa_paths)}) against {graded}, "
               f"so the review panel does not run on this PR.\n\nPR: {pr.get('html_url', '')}")
    return {"checks": [{"name": n, "head_sha": head, "conclusion": "success", "external_id": SCOPE_EXTERNAL_ID,
                        "title": f"{labels[n]}: out of scope, no QA-owned path ({graded})", "summary": summary}
                       for n in names],
            "request_qa_review": False, "pr_number": pr.get("number"), "base_ref": base_ref}


def decide_bot(event, bots, check_name, test_check="qa-test-run", passed_before=lambda sha: False):
    """Map a pull_request event to the two green check-runs, or to a skip.
    The bot pushes again after opening (backport-fix-imports) on top of the branch tip, so its
    synchronize counts only when the tip it built on (`before`) was itself a bot-passed head."""
    pr = event.get("pull_request") or {}
    login = bot_pr(pr, bots)
    if login is None:
        return {"skip": f"PR by {(pr.get('user') or {}).get('login') or 'unknown'} is not a trusted bot PR"}
    pusher = (event.get("sender") or {}).get("login", "")
    action = event.get("action")
    if action not in ("opened", "synchronize") or pusher != login:
        return {"skip": "only a head the bot pushed passes; the panel reviews this head", "final": True}
    if action == "synchronize" and not passed_before(event.get("before") or ""):
        return {"skip": "the bot built on a head the gate had not passed; the panel reviews this head",
                "final": True}
    return {"checks": bot_checks(pr, login, bots[login], check_name, test_check), "request_qa_review": False,
            "pr_number": pr.get("number")}


def decide_pull_request(event, repo, token, bots, qa_paths, check_name, test_check="qa-test-run",
                        passed_before=lambda sha: False):
    """A pull_request event: the trusted-bot pass first, then the QA-scope pass for any other
    PR. A trusted bot PR whose exemption was declined goes to review whatever it touches."""
    decision = decide_bot(event, bots, check_name, test_check, passed_before=passed_before)
    if "skip" not in decision or decision.get("final"):
        return decision
    print(f"::notice::qa-review-gate: {decision['skip']}")
    pr = event.get("pull_request") or {}
    graded, current = (pr.get("base") or {}).get("ref", ""), current_base(repo, pr.get("number"), token)
    if current != graded:
        # A queued `opened` job must not green a head the PR has since retargeted.
        return {"skip": f"PR now targets {current}, not {graded}; the retarget event grades it"}
    return decide_scope(event, repo, token, qa_paths, check_name, test_check)


def regrade_if_retargeted(event, repo, token, qa_paths, check_name, test_check, qa_team, run_url, panel_login):
    """After a scope write: a retarget that landed meanwhile grades the head again, as its
    `edited` event would, so the pass just written cannot outlive the base it graded."""
    pr = event.get("pull_request") or {}
    current = gh_api([f"repos/{repo}/pulls/{pr.get('number')}"], token)
    if ((current.get("base") or {}).get("ref", "")) == (pr.get("base") or {}).get("ref", ""):
        return None
    if ((current.get("head") or {}).get("sha", "")) != (pr.get("head") or {}).get("sha", ""):
        # This job queues on the old head; the new head's own event grades it in its queue.
        print(f"::notice::qa-review-gate: retargeted and moved to {current['head']['sha'][:7]}; its own event grades it")
        return None
    edited = {"action": "edited", "changes": {"base": {"ref": {"from": (pr.get("base") or {}).get("ref", "")}}},
              "pull_request": current, "sender": event.get("sender") or {}}
    decision = decide_scope(edited, repo, token, qa_paths, check_name, test_check)
    if "skip" in decision:
        print(f"::notice::qa-review-gate: {decision['skip']}")
        return None
    apply(decision, repo, token, qa_team, run_url, panel_login)
    return decision


def missing_checks(repo, head, names, token):
    """The check names in `names` with no completed run from GitHub Actions on `head`."""
    missing = []
    for name in names:
        runs = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={name}"], token).get("check_runs"))
        if not any(run.get("status") == "completed" for run in runs):
            missing.append(name)
    return missing


def sweep(repo, token, check_name, test_check, caller_workflow):
    """Before the ruleset goes live: start one run of the caller workflow per open PR whose
    current head lacks either check. Each run grades its PR under that head's own queue
    (`sweep_one`), so it cannot cross a panel verdict or an e2e result on the way; this job
    only lists and dispatches. `caller_workflow` is `github.workflow_ref`."""
    path, _, ref = caller_workflow.partition("@")
    workflow = path.rsplit("/", 1)[-1]
    pages = gh_api([f"repos/{repo}/pulls?state=open&per_page=100", "--paginate", "--slurp"], token)
    dispatched = []
    for pr in (pr for page in pages for pr in page):
        number = pr.get("number")
        pr = gh_api([f"repos/{repo}/pulls/{number}"], token) or pr
        head = (pr.get("head") or {}).get("sha", "")
        if not missing_checks(repo, head, (check_name, test_check), token):
            continue
        gh_api([f"repos/{repo}/actions/workflows/{workflow}/dispatches", "-X", "POST"], token,
               {"ref": ref, "inputs": {"pr-number": str(number)}})
        dispatched.append(number)
        print(f"qa-review-gate: #{number} {head[:7]} lacks a check; started a run for it")
    print(f"qa-review-gate: sweep started {len(dispatched)} run(s): {', '.join(f'#{n}' for n in dispatched) or 'none'}")
    return len(dispatched)


def sweep_one(repo, token, number, queued_sha, bots, qa_paths, check_name, test_check, qa_team, run_url,
              panel_login):
    """One PR of the sweep, run under the queue of `queued_sha` (the head the `tested` job
    resolved): the QA-scope pass it would have got on `opened`, creating only what is missing
    (a retry after a partial write completes it). A PR that moved to another head since is
    graded by that head's own event; a PR that touches a QA-owned path gets the checks that
    wait for the panel; a trusted bot PR on a later head is left to a person, with a warning."""
    pr = gh_api([f"repos/{repo}/pulls/{number}"], token)
    head = (pr.get("head") or {}).get("sha", "")
    if head != queued_sha:
        print(f"::notice::qa-review-gate: #{number} is on {head[:7]}, this run queued for "
              f"{queued_sha[:7] or 'no head'}; the head's own event grades it")
        return False
    missing = missing_checks(repo, head, (check_name, test_check), token)
    if not missing:
        print(f"qa-review-gate: #{number} {head[:7]} has both checks")
        return False
    reason = None
    if bot_pr(pr, bots):
        reason = "a trusted bot PR on a later head; a person reviews it"
    else:
        event = {"action": "opened", "pull_request": pr, "sender": pr.get("user") or {}}
        decision = decide_scope(event, repo, token, qa_paths, check_name, test_check)
        reason = decision.get("skip")
    if reason:
        print(f"::warning::qa-review-gate: #{number} {head[:7]} still lacks {', '.join(missing)} ({reason}); "
              "needs /vcluster-review from a person or /qa-review override before the ruleset is enabled")
        return False
    decision["checks"] = [c for c in decision["checks"] if c["name"] in missing]
    apply(decision, repo, token, qa_team, run_url, panel_login)
    print(f"qa-review-gate: #{number} {head[:7]} {decision['checks'][0]['title']} ({', '.join(missing)} created)")
    if regrade_if_retargeted(event, repo, token, qa_paths, check_name, test_check, qa_team, run_url, panel_login):
        print(f"qa-review-gate: #{number} {head[:7]} retargeted meanwhile; graded again")
    return True


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
    verdict, classes, head, base = parsed
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
                  "title": title, "summary": summary, "external_id": VERDICT_EXTERNAL_ID},
        "request_qa_review": False,
        "assign_author": verdict == "needs_human",
        "pr_number": pr.get("number"),
        "base_ref": base,
    }


def test_run_pending(added, head, pr_number, test_check, run_hint="/test-e2e <label-filter>"):
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
                      "summary": f"New specs this PR adds:\n\n{lines}\n\nRun `{run_hint}` with a filter covering the listed specs; the "
                                 f"check turns green when they ran and passed. {OVERRIDE_HINT}"},
            "request_qa_review": False, "pr_number": pr_number}


def collect_review(event, repo, token, panel_login, check_name, test_check="qa-test-run"):
    """The verdict check-run plus, when no `qa-test-run` exists on the head yet, its opener."""
    decision = decide_review(event, panel_login, check_name)
    if "skip" in decision:
        return decision
    head = decision["check"]["head_sha"]
    pr_number = decision["pr_number"]
    live = ((gh_api([f"repos/{repo}/pulls/{pr_number}"], token).get("base") or {}).get("ref", ""))
    if live != decision["base_ref"]:
        # A panel run that started before a retarget graded the old diff; the panel runs again.
        return {"skip": f"marker is for base {decision['base_ref']}, PR targets {live or 'unknown'}; "
                        "the panel reviews the new base"}
    graded = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={check_name}&filter=all&per_page=100"], token).get("check_runs"))
    newest = max(graded, key=lambda run: run.get("id", 0), default=None)
    if (newest and kind(newest) == SCOPE_EXTERNAL_ID and newest.get("conclusion") == "success"
            and base_of(newest) == decision["base_ref"]):
        # A /vcluster-review on a PR with no QA-owned path is advice: it must not block the PR,
        # only for the next commit to pass it again as out of scope.
        return {"skip": "the PR touches no QA-owned path; the panel's verdict does not replace its out-of-scope pass"}
    existing = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={test_check}"], token).get("check_runs"))
    if existing and not scope_may_write(existing, decision["base_ref"]):
        # A retry: our own provisional opener may still hide a real result behind it.
        decision["reconcile"] = test_check
        return decision
    try:
        added = added_specs(pr_diff(repo, decision["base_ref"], head, token))
        opener = test_run_pending(added, head, pr_number, test_check)
    except GateError as error:
        opener = ask_person(test_check, head, pr_number,
                            "QA test run: cannot identify new specs, a person checks them",
                            str(error))
    decision["checks"] = [decision.pop("check"), opener["check"]]
    decision["opener_name"] = test_check
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
    if not words or words[0] != command:
        return {"skip": "comment does not open with the command"}
    if len(words) < 2:
        return {"skip": f"{command} needs a verb; use `{command} override [<reason>]` or `{command} human`",
                "pr_number": issue.get("number")}
    author = (comment.get("user") or {}).get("login", "")
    verb = words[1]
    if verb == "override":
        if author not in override_logins and not member(author):
            return {"skip": f"{author or 'unknown'} is not an override login or team member; override ignored",
                    "pr_number": issue.get("number")}
        rest = words[2:]
        sha_prefix = rest.pop(0) if rest and SHA_PREFIX.match(rest[0]) else None
        reason = " ".join(rest).strip() or "no reason given"
        summary = (f"@{author} overrode the panel verdict: {reason}\n\n"
                   f"Comment: {comment.get('html_url', '')}")
        return {
            "checks": [{"name": check_name, "head_sha": None, "conclusion": "success",
                        "external_id": OVERRIDE_EXTERNAL_ID,
                        "title": f"QA review: overridden by @{author}", "summary": summary},
                       {"name": test_check, "head_sha": None, "conclusion": "success",
                        "external_id": OVERRIDE_EXTERNAL_ID,
                        "title": f"QA test run: overridden by @{author}", "summary": summary}],
            "request_qa_review": False,
            "pr_number": issue.get("number"),
            "comment_at": comment.get("created_at", ""),
            "binds_to_marker": True,
            "sha_prefix": sha_prefix,
        }
    if verb == "human":
        if comment.get("author_association") not in MEMBER_ASSOCIATIONS:
            return {"skip": f"{author or 'unknown'} may not ask for a QA review here", "pr_number": issue.get("number")}
        return {
            "check": {"name": check_name, "head_sha": None, "conclusion": "action_required",
                      "external_id": HUMAN_EXTERNAL_ID, "title": "QA review: a QA engineer decides",
                      "summary": f"@{author} asked for a person.\n\nComment: "
                                 f"{comment.get('html_url', '')}"},
            "request_qa_review": True,
            "pr_number": issue.get("number"),
            "comment_at": comment.get("created_at", ""),
        }
    return {"skip": f"unknown {command} verb {verb!r}; use override [<reason>] or human",
            "pr_number": issue.get("number")}


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
            if ADDED_DECLARATION.match(raw) and not LITERAL_DECLARATION.match(raw):
                raise GateError(f"Cannot identify added spec or container at {path}:{line}; "
                                "run `/test-e2e <label-filter>` covering the added specs and ask for an override.")
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


def parse_time(text):
    """An aware datetime from an RFC 3339 stamp (Ginkgo writes nanoseconds), or None."""
    try:
        when = datetime.fromisoformat(re.sub(r"(\.\d{1,6})\d*", r"\1", text or "").replace("Z", "+00:00"))
    except ValueError:
        return None
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def report_specs(report, states=None, idle=None, started=None):
    """{(file, line): state} for every leaf spec in a Ginkgo JSON report (a list of suites).
    The file is the runner's absolute path; spec_state matches it by suffix. A dry-run suite
    reports `passed` without running, so it is left out. With `idle`, a spec the run never
    attempted (a label filter skipped it: NumAttempts 0) goes there instead. `started`
    collects when each attempted spec last started."""
    states = {} if states is None else states
    for suite in report if isinstance(report, list) else []:  # a failure dump beside the report is no report
        if (suite.get("SuiteConfig") or {}).get("DryRun"):
            continue
        for spec in suite.get("SpecReports") or []:
            if spec.get("LeafNodeType") in ("It", "Specify", None):
                loc = spec.get("LeafNodeLocation") or {}
                key = (loc.get("FileName", ""), loc.get("LineNumber", 0))
                attempted = idle is None or spec.get("NumAttempts", 1) != 0
                merge_state(states if attempted else idle, key, spec.get("State", ""))
                when = parse_time(spec.get("StartTime"))
                if attempted and started is not None and when and when > started.get(key, when.min.replace(tzinfo=timezone.utc)):
                    started[key] = when
    return states


def latest_states(layers, added):
    """{(path, line): state} per new spec from report layers (states, idle, started, uploaded):
    the attempt that started last (the upload time when the report has no start time), else
    the newest report that only skipped it."""
    floor = datetime.min.replace(tzinfo=timezone.utc)
    found = {}
    for spec in added:
        ran = [(spec_state(started, spec) or uploaded or floor, n, spec_state(states, spec))
               for n, (states, _, started, uploaded) in enumerate(layers) if spec_state(states, spec) is not None]
        skipped = [spec_state(idle, spec) for _, idle, _, _ in layers if spec_state(idle, spec) is not None]
        if ran or skipped:
            found[(spec["path"], spec["line"])] = max(ran)[2] if ran else skipped[-1]
    return found


def spec_state(states, spec):
    """The reported state of the spec declared at spec["path"]:spec["line"], or None."""
    for (file, line), state in states.items():
        if line == spec["line"] and (file == spec["path"] or file.endswith("/" + spec["path"])):
            return state
    return None


def parse_trees(text):
    """{report artifact: path prefix} from `artifact=prefix,artifact=prefix`. A repo whose e2e
    workflows each test one source tree (vcluster-pro: Pro, and OSS under staging/) uploads one
    report per tree; the empty prefix is the tree every other path belongs to."""
    trees = {}
    for item in filter(None, (s.strip() for s in (text or "").split(","))):
        artifact, sep, prefix = item.partition("=")
        if not sep or not artifact:
            raise GateError(f"report-trees entry must be artifact=path-prefix, got {item!r}")
        trees[artifact] = prefix
    return trees or {REPORT_ARTIFACT: ""}


def spec_tree(spec, trees):
    """The report artifact that covers a spec: the longest prefix its path starts with."""
    return max((a for a, p in trees.items() if spec["path"].startswith(p)),
               key=lambda a: len(trees[a]), default=REPORT_ARTIFACT)


def grade(run, added, states):
    """(conclusion, lines) for the specs of one tree against that tree's report."""
    graded = [(f"{s['path']}:{s['line']} {s['text']}", spec_state(states, s)) for s in added]
    missing = [f"- did not run: {label}" for label, state in graded if state is None]
    not_passed = [f"- {label} ({state})" for label, state in graded if state not in (None, "passed")]
    if missing or not_passed:
        return "failure", missing + not_passed, len(missing) + len(not_passed)
    return "success", [f"- {len(added)} spec(s) ran and passed in {run.get('html_url', '')}"], 0


def trees_id(results):
    return TREES_EXTERNAL_ID + ";".join(f"{a}={c}" for a, c in sorted(results.items()))


def tree_results(repo, head, test_check, token, base=""):
    """Per-tree conclusions recorded on the newest `qa-test-run` check-run of this head that
    was graded against `base`."""
    runs = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={test_check}&filter=all&per_page=100"], token).get("check_runs"))
    tagged = [r for r in runs if kind(r).startswith(TREES_EXTERNAL_ID) and base_of(r) == base]
    if not tagged:
        return {}
    newest = kind(max(tagged, key=lambda r: r["id"]))[len(TREES_EXTERNAL_ID):]
    return dict(item.split("=", 1) for item in newest.split(";") if "=" in item)


def decide_ci(run, pr_number, added, states, test_check="qa-test-run", trees=None,
              reported=None, known=None):
    """Compare the PR's new specs with what the e2e run reported. With several trees, this run
    grades the trees it reported on; `known` carries the other trees' results from earlier runs,
    and the check completes only when every tree with new specs has a result."""
    if run.get("conclusion") not in ("success", "failure"):
        return {"skip": f"e2e run ended {run.get('conclusion') or 'unknown'}, nothing to compare"}
    if not added:
        return {"skip": "the PR adds no e2e spec"}
    trees = trees or {REPORT_ARTIFACT: ""}
    reported = set(reported) if reported is not None else set(trees)
    results, lines, bad = dict(known or {}), [], 0
    by_tree = {}
    for s in added:
        by_tree.setdefault(spec_tree(s, trees), []).append(s)
    for artifact, specs in by_tree.items():
        if artifact in reported:
            results[artifact], tree_lines, tree_bad = grade(run, specs, states)
            bad += tree_bad
            lines += ([f"{artifact}:"] if len(trees) > 1 else []) + tree_lines
        elif artifact in results:
            lines.append(f"- {artifact}: {results[artifact]} in an earlier run")
    waiting = [a for a in by_tree if a not in results]
    head = run.get("head_sha", "")
    if waiting:
        conclusion = "action_required"
        title = f"QA test run: waiting for {', '.join(waiting)} ({sum(len(by_tree[a]) for a in waiting)} new spec(s))"
        lines += [f"- {a}: {len(by_tree[a])} new spec(s), no run reported yet" for a in waiting]
    elif any(results[a] == "failure" for a in by_tree):
        conclusion = "failure"
        failed = ", ".join(a for a in by_tree if results[a] == "failure")
        title = (f"QA test run: {bad} new spec(s) did not run or pass" if bad
                 else f"QA test run: new spec(s) for {failed} did not run or pass in an earlier run")
        lines.append("\nA spec that the PR run does not select (a nightly label, another label filter) "
                     "lands here as skipped or \"did not run\": run it with `/test-e2e <label-filter>` on "
                     "the last commit. When `/test-e2e` cannot run it (it needs an environment only the "
                     f"nightly run has), ask QA or a tech lead for an override. {OVERRIDE_HINT} "
                     "For a focused or skipped spec, fix the spec and push.")
    else:
        conclusion = "success"
        title = f"QA test run: all {len(added)} new spec(s) ran and passed"
    summary = "New specs this PR adds, checked against the Ginkgo report(s):\n\n" + "\n".join(lines)
    return {
        "check": {"name": test_check, "head_sha": head, "conclusion": conclusion,
                  "title": title, "summary": summary, "external_id": trees_id(results)},
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


def run_base(run):
    """The base a PR-triggered e2e run merged the head with, from its title (`onto <ref>`);
    a dispatch run checks out the head alone, so its report holds for any base."""
    if run.get("event") != "pull_request":
        return None
    named = RUN_BASE.search(run.get("display_title") or "")
    return named.group(1) if named else ""


def run_target(run, repo, token):
    """(tested commit, PR number) of an e2e run. A /test-e2e run on a fork PR dispatches the
    base branch's workflow, so `head_sha` is the base commit; the run-name carries the PR
    and the commit it checked out (`E2E for PR #<n> (<label>) at <sha>`)."""
    if run.get("event") == "workflow_dispatch":
        named = DISPATCH_TITLE.search(run.get("display_title") or "")
        if named:
            return named.group(2), int(named.group(1))
    return run.get("head_sha", ""), run_pr_number(run, repo, token)


def parse_workflows(text):
    return {name.strip() for name in (text or "").split(",") if name.strip()}


def e2e_runs(run, repo, head, pr_number, base_ref, workflows, token):
    """Every finished run of the e2e workflows that tested `head`, `run` included: one PR can
    need several runs (label filters, a second e2e workflow) before each new spec has run.
    `workflows` (names) are the caller's `workflow_run` list; empty: the workflow of `run`.
    Matched by workflow id: a run's own `name` is its run-name, which differs per run."""
    pages = gh_api([f"repos/{repo}/actions/workflows?per_page=100", "--paginate", "--slurp"], token) if workflows else []
    listed = [w for page in pages for w in page.get("workflows") or []]
    ids = {w["id"] for w in listed if w.get("name") in workflows} | {run.get("workflow_id")}

    def tested(r):
        named = r.get("event") == "workflow_dispatch" and DISPATCH_TITLE.search(r.get("display_title") or "")
        return (named.group(2), int(named.group(1))) == (head, pr_number) if named else r.get("head_sha") == head
    # A fork PR's /test-e2e run has the base commit as head_sha: found on the base branch by its title.
    # ponytail: the newest 100 dispatch runs of the base branch; page when a head waits behind more
    listed = [r for query in (f"head_sha={head}", f"branch={base_ref}&event=workflow_dispatch")
              for r in gh_api([f"repos/{repo}/actions/runs?{query}&status=completed&per_page=100"],
                              token).get("workflow_runs") or []]
    runs = {r["id"]: r for r in listed
            if r.get("workflow_id") in ids and r.get("conclusion") in ("success", "failure")
            and r.get("event") in ("pull_request", "workflow_dispatch")
            and tested(r) and run_base(r) in (None, base_ref)}
    runs[run["id"]] = run
    return list(runs.values())


def artifact_tree(name, trees):
    """The tree a report artifact belongs to: named as the tree, or `<tree>.<job>` per matrix job.
    The dot is a promise of the producer: `<tree>-<job>` from an older workflow is not read."""
    return max((t for t in trees if name == t or name.startswith(t + ".")), key=len, default=None)


def report_artifacts(runs, repo, trees, token):
    """The unexpired report artifacts of `runs`, oldest upload first. A re-run keeps the run id
    and adds a second artifact of the same name, so each is read by its own id."""
    found = [a for r in runs
             for a in gh_api([f"repos/{repo}/actions/runs/{r['id']}/artifacts"], token).get("artifacts") or []
             if artifact_tree(a["name"], trees) and not a.get("expired")]
    return sorted(found, key=lambda a: a.get("created_at", ""))


def download_report(repo, artifact, dest, token):
    """Unpack one artifact by id: `gh run download -n` cannot tell two attempts' artifacts apart."""
    result = subprocess.run(["gh", "api", f"repos/{repo}/actions/artifacts/{artifact['id']}/zip"],
                            capture_output=True, env={**os.environ, "GH_TOKEN": token}, check=False)
    if result.returncode:
        raise GateError(f"artifact {artifact['id']} download failed: {result.stderr.decode(errors='replace').strip()}")
    try:
        zipfile.ZipFile(io.BytesIO(result.stdout)).extractall(dest)
    except zipfile.BadZipFile as error:
        raise GateError(f"artifact {artifact['id']} is no zip: {error}") from error


def pr_diff(repo, base_ref, head_sha, token):
    """The diff of the commits an e2e run tested: the PR base compared with the run's head
    (three dots, so from the merge base), in the `+++ b/<path>` shape added_specs reads."""
    files = gh_api([f"repos/{repo}/compare/{base_ref}...{head_sha}"], token).get("files") or []
    if len(files) >= COMPARE_FILE_CAP:
        raise GateError(f"compare lists {COMPARE_FILE_CAP} files; the diff may be cut")
    for f in files:
        path = f["filename"]
        if path.endswith(".go") and "/e2e" in f"/{path}" and f.get("additions", 1) > 0 and not f.get("patch"):
            raise GateError(f"No usable diff for {path}; cannot identify added specs")
    return "\n".join(f"+++ b/{f['filename']}\n{f.get('patch') or ''}" for f in files)


def ask_person(test_check, head, pr_number, title, detail):
    """A `qa-test-run` check-run nobody can grade automatically: a person decides."""
    return {"check": {"name": test_check, "head_sha": head, "conclusion": "action_required",
                      "title": title,
                      "summary": f"{detail}\n\nRe-run `/test-e2e <label-filter>`, or ask for an override. {OVERRIDE_HINT}"},
            "request_qa_review": False, "pr_number": pr_number}


def collect_ci(event, repo, token, test_check="qa-test-run", trees=None, workflows=None):
    """Fetch the diff and the Ginkgo report(s) for a finished e2e run, then decide."""
    trees = trees or {REPORT_ARTIFACT: ""}
    run = event.get("workflow_run") or {}
    if run.get("conclusion") not in ("success", "failure"):
        return {"skip": f"e2e run ended {run.get('conclusion') or 'unknown'}, nothing to compare"}
    head, pr_number = run_target(run, repo, token)
    run = {**run, "head_sha": head}
    if pr_number is None:
        return {"skip": "e2e run is not for an open pull request"}
    try:
        pr = gh_api([f"repos/{repo}/pulls/{pr_number}"], token)
    except GateError as error:
        return ask_person(test_check, head, pr_number,
                          "QA test run: cannot identify new specs, a person checks them", str(error))
    current, base_ref = pr["head"]["sha"], pr["base"]["ref"]
    if current != head:
        return {"skip": f"e2e run is for {head[:7]}, PR head is {current[:7]}; superseded"}
    tested = run_base(run)
    if tested == "":
        return {"skip": "the e2e run names no base (its run-name lacks `onto <base-ref>`), so the gate "
                        "cannot tell which base its merge commit used; a run that names it grades the PR"}
    if tested is not None and tested != base_ref:
        return {"skip": f"the e2e run tested the head onto {tested}, the PR now targets {base_ref}; "
                        "a new run grades it"}

    def graded_against(decision):
        return {**decision, "base_ref": base_ref}
    try:
        added = added_specs(pr_diff(repo, base_ref, head, token))
    except GateError as error:
        return graded_against(ask_person(test_check, head, pr_number,
                                         "QA test run: cannot identify new specs, a person checks them",
                                         str(error)))
    if not added:
        return {"skip": "the PR adds no e2e spec"}
    artifacts = report_artifacts(e2e_runs(run, repo, head, pr_number, base_ref, workflows, token),
                                 repo, trees, token)
    reported = [t for t in trees if any(artifact_tree(a["name"], trees) == t for a in artifacts)]
    known = tree_results(repo, head, test_check, token, base_ref) if len(trees) > 1 else {}
    if not reported:
        # A run that uploaded nothing (build failure) must not drop the other tree's result.
        missing = sorted({spec_tree(s, trees) for s in added} - set(known))
        if not missing:
            return graded_against(decide_ci(run, pr_number, added, {}, test_check, trees, [], known))
        count = sum(spec_tree(s, trees) in missing for s in added)
        decision = ask_person(test_check, head, pr_number,
                              f"QA test run: no {' or '.join(missing)} for {count} new spec(s), "
                              "a person checks them", f"run {run.get('html_url', '')} uploaded no report")
        if known:
            decision["check"]["external_id"] = trees_id(known)
        return graded_against(decision)
    layers = []
    with tempfile.TemporaryDirectory() as tmp:
        for n, artifact in enumerate(artifacts):
            try:
                download_report(repo, artifact, os.path.join(tmp, str(n)), token)
            except GateError as error:
                return graded_against(ask_person(
                    test_check, head, pr_number,
                    f"QA test run: {artifact['name']} could not be read, a person checks the new specs", str(error)))
            layers.append(({}, {}, {}, parse_time(artifact.get("created_at"))))
            for path in sorted(glob.glob(os.path.join(tmp, str(n), "**", "*.json"), recursive=True)):
                with open(path, encoding="utf-8") as fh:
                    report_specs(json.load(fh), *layers[-1][:3])
    states = latest_states(layers, added)
    return graded_against(decide_ci(run, pr_number, added, states, test_check, trees, reported, known))


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


def reply(repo, pr_number, text, token):
    """Tell the PR why a /qa-review comment changed nothing; the job log alone goes unread. Best effort."""
    try:
        gh_api([f"repos/{repo}/issues/{pr_number}/comments"], token, {"body": f"QA review gate: {text}"})
    except GateError as error:
        print(f"::warning::qa-review-gate: could not reply on #{pr_number}: {error}")


def head_at(repo, pr, comment_at, token):
    """The sha a `pull_request` run of this PR tested last before `comment_at`: the PR's head at
    that time. None when no run tells (no workflow on pull_request, a fork PR, or the first run came later)."""
    head = pr["head"]
    runs = gh_api([f"repos/{repo}/actions/runs?event=pull_request&branch={head.get('ref', '')}"
                   f"&created=<={comment_at}&per_page=50"], token).get("workflow_runs") or []
    # By PR number only: one branch can back two PRs. A fork PR's runs name no PR, so its lead names the sha.
    mine = [r for r in runs if pr["number"] in [p.get("number") for p in r.get("pull_requests") or []]]
    return max(mine, key=lambda r: r.get("created_at", ""))["head_sha"] if mine else None


def comment_head(decision, repo, token, panel_login):
    """(head, None) for the PR head a /qa-review comment applies to, or (None, why not). An
    override lands on the head its author saw: one the panel graded before the comment, or the
    one this PR's CI ran on last before the comment. Else the login names the head:
    `/qa-review override <sha>`."""
    pr_number = decision["pr_number"]
    pr = gh_api([f"repos/{repo}/pulls/{pr_number}"], token)
    head = pr["head"]["sha"]
    if not decision.get("binds_to_marker"):
        return head, None
    if decision.get("sha_prefix"):
        return (head, None) if head.startswith(decision["sha_prefix"]) else (
            None, f"The commit you named is not the PR head, which is `{head[:7]}`.")
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
            return head, None
    try:
        seen = head_at(repo, {**pr, "number": pr_number}, decision.get("comment_at", ""), token)
    except GateError:
        seen = None
    if seen == head:
        return head, None
    hint = f"Check it and comment again, or name the commit: `/qa-review override {head[:7]} <reason>`."
    if seen:
        return None, f"The PR head was `{seen[:7]}` when you commented and is `{head[:7]}` now. {hint}"
    return None, f"I cannot tell if `{head[:7]}` was the PR head when you commented. {hint}"


def reconcile_opener(repo, head, name, opener_id, token, run_url):
    """Copy the newest real result onto a provisional opener it would otherwise hide.
    `opener_id` None means: the newest run on the head, if it is a provisional opener."""
    runs = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={name}&filter=all&per_page=100"], token).get("check_runs"))
    if opener_id is None:
        newest = max(runs, key=lambda run: run.get("id", 0), default=None)
        if not newest or kind(newest) != OPENER_EXTERNAL_ID:
            return
        opener_id = newest["id"]
    opener_base = next((base_of(run) for run in runs if run.get("id") == opener_id), "")
    previous = [run for run in runs
                if run.get("id", 0) < opener_id and run.get("status") == "completed"
                and kind(run) not in (OPENER_EXTERNAL_ID, SCOPE_EXTERNAL_ID)
                and (kind(run) == OVERRIDE_EXTERNAL_ID or base_of(run) == opener_base)]
    if not previous:
        return
    # An override outranks any result, however new; a result only fills an empty opener.
    overrides = [run for run in previous if kind(run) == OVERRIDE_EXTERNAL_ID]
    result = max(overrides or previous, key=lambda run: run["id"])
    output = result.get("output") or {}
    gh_api([f"repos/{repo}/check-runs/{opener_id}", "-X", "PATCH"], token, {
        "status": "completed", "conclusion": result["conclusion"],
        "details_url": result.get("details_url") or run_url,
        "output": {"title": output.get("title", ""), "summary": output.get("summary", "")},
    })
    # An override may have landed after the read above; put it back on top.
    reconcile_override(repo, head, name, token, run_url)


def override_run(repo, head, name, token):
    """The newest /qa-review override that completed `name` on `head`, or None."""
    runs = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={name}&filter=all&per_page=100"], token).get("check_runs"))
    overrides = [run for run in runs if kind(run) == OVERRIDE_EXTERNAL_ID]
    return max(overrides, key=lambda run: run.get("id", 0)) if overrides else None


def overridden(repo, head, name, token):
    return override_run(repo, head, name, token) is not None


def reconcile_scope_write(repo, head, name, created_id, since_id, token, run_url):
    """A scope write runs outside the head's queue (the sweep) or after its ownership read:
    a panel verdict or an e2e result that landed in between (id after `since_id`, before
    ours) must not be hidden by ours, so it is copied onto our run, ownership included."""
    runs = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={name}&filter=all&per_page=100"], token).get("check_runs"))
    landed = [run for run in runs if since_id < run.get("id", 0) < created_id
              and run.get("status") == "completed"
              and kind(run) not in (SCOPE_EXTERNAL_ID, OPENER_EXTERNAL_ID)]
    if not landed:
        return False
    winner = max(landed, key=lambda run: run["id"])
    output = winner.get("output") or {}
    gh_api([f"repos/{repo}/check-runs/{created_id}", "-X", "PATCH"], token, {
        "status": "completed", "conclusion": winner.get("conclusion", "success"),
        "details_url": winner.get("details_url") or run_url, "external_id": winner.get("external_id") or "",
        "output": {"title": output.get("title", ""), "summary": output.get("summary", "")},
    })
    print(f"::notice::qa-review-gate: {name} on {head[:7]}: a result landed during the scope write; kept it")
    return True


def reconcile_override(repo, head, name, token, run_url):
    """Make the newest run of `name` on `head` show the override, when one exists. A result
    published after the override, or one whose repair PATCH failed, would otherwise stay
    on top; a rerun of the gate lands here and fixes it."""
    runs = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={name}&filter=all&per_page=100"], token).get("check_runs"))
    overrides = [run for run in runs if kind(run) == OVERRIDE_EXTERNAL_ID]
    if not overrides or not runs:
        return False
    winner = max(overrides, key=lambda run: run.get("id", 0))
    newest = max(runs, key=lambda run: run.get("id", 0))
    if newest["id"] == winner["id"]:
        return False
    output = winner.get("output") or {}
    gh_api([f"repos/{repo}/check-runs/{newest['id']}", "-X", "PATCH"], token, {
        "status": "completed", "conclusion": winner.get("conclusion", "success"),
        "details_url": winner.get("details_url") or run_url,
        "output": {"title": output.get("title", ""), "summary": output.get("summary", "")},
    })
    return True


def wait_for_bot_pass(repo, sha, check_name, token, attempts=15, delay=20, sleep=time.sleep):
    """`bot_passed`, retried: the `opened` and `synchronize` gate jobs of one bot PR run in
    either order, so the import fix may arrive before the opened head carries its pass."""
    for attempt in range(attempts):
        if bot_passed(repo, sha, check_name, token):
            return True
        if attempt + 1 < attempts:
            sleep(delay)
    return False


def apply(decision, repo, token, qa_team, run_url, panel_login="loft-bot"):
    """Create the check-run(s), hand the PR to its author or request the QA team when asked.
    Returns the head the checks landed on, or None when the comment binds to no verdict."""
    checks = decision.get("checks") or [decision["check"]]
    head = checks[0]["head_sha"]
    if head is None:
        head, why = comment_head(decision, repo, token, panel_login)
        if head is None:
            print(f"::notice::qa-review-gate: the override did nothing. {why}")
            reply(repo, decision["pr_number"], f"the override did nothing. {why}", token)
            return None
    for check in checks:
        if check.get("external_id") != OVERRIDE_EXTERNAL_ID and overridden(repo, head, check["name"], token):
            # A late e2e result or panel verdict must not undo an authorized override.
            reconcile_override(repo, head, check["name"], token, run_url)
            print(f"::notice::qa-review-gate: {check['name']} on {head[:7]} stays overridden")
            continue
        if check["name"] == decision.get("opener_name"):
            existing = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={check['name']}"], token).get("check_runs"))
            if existing and not scope_may_write(existing, decision.get("base_ref", "")):
                # A retry after a failed reconciliation: the newest run may still be our
                # provisional opener while a real result sits behind it.
                reconcile_opener(repo, head, check["name"], None, token, run_url)
                continue
        since = 0
        if check.get("external_id") == SCOPE_EXTERNAL_ID:
            # One read for both: a request for a person or a verdict that landed after decide_scope
            # read ownership is at or below the watermark, so the reconciliation would not see it.
            runs = from_actions(gh_api([f"repos/{repo}/commits/{head}/check-runs?check_name={check['name']}&filter=all&per_page=100"], token).get("check_runs"))
            if not scope_may_write(runs, decision.get("base_ref", "")):
                print(f"::notice::qa-review-gate: {check['name']} on {head[:7]} got a result since the scope check; kept it")
                continue
            since = max((run.get("id", 0) for run in runs), default=0)
        external_id = OPENER_EXTERNAL_ID if check["name"] == decision.get("opener_name") else check.get("external_id") or ""
        if external_id not in (OVERRIDE_EXTERNAL_ID, BOT_EXTERNAL_ID, HUMAN_EXTERNAL_ID):
            external_id = with_base(external_id, decision.get("base_ref", ""))
        # An out-of-scope pass comes back by itself on the next commit; every other result does not.
        note = "" if "out of scope" in check["title"] else (
            f"\n\nThis result is for commit `{head[:7]}` only. A new commit resets this check.")
        created = gh_api([f"repos/{repo}/check-runs", "-X", "POST"], token, {
            "name": check["name"], "head_sha": head, "status": "completed",
            "conclusion": check["conclusion"], "details_url": run_url,
            "output": {"title": check["title"], "summary": check["summary"] + note},
            **({"external_id": external_id} if external_id else {}),
        })
        if check["name"] == decision.get("opener_name"):
            # A result may have been published after our lookup but before this
            # opener. Copy it onto the newer opener without creating another run:
            # any result published after the opener remains the newest check.
            reconcile_opener(repo, head, check["name"], created["id"], token, run_url)
        elif check.get("external_id") != OVERRIDE_EXTERNAL_ID:
            if check.get("external_id") == SCOPE_EXTERNAL_ID:
                reconcile_scope_write(repo, head, check["name"], created["id"], since, token, run_url)
            # An override may have landed between the lookup and this write. The newest
            # run is what GitHub shows, so copy the override onto ours.
            reconcile_override(repo, head, check["name"], token, run_url)
    if decision.get("reconcile"):
        reconcile_opener(repo, head, decision["reconcile"], None, token, run_url)
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
        decision = collect_ci(event, repo, token, test_check,
                              parse_trees(os.environ.get("INPUT_REPORT_TREES", DEFAULT_TREES)),
                              parse_workflows(os.environ.get("INPUT_E2E_WORKFLOWS", "")))
    elif mode == "bot":
        decision = decide_pull_request(event, repo, token,
                                       parse_bots(os.environ.get("INPUT_BOT_PRS", DEFAULT_BOTS)),
                                       parse_paths(os.environ.get("INPUT_QA_PATHS", DEFAULT_QA_PATHS)),
                                       check_name, test_check,
                                       passed_before=lambda sha: wait_for_bot_pass(repo, sha, check_name, token))
    elif mode == "sweep":
        number = os.environ.get("INPUT_PR_NUMBER", "").strip()
        if number:
            sweep_one(repo, token, int(number), os.environ.get("INPUT_QUEUED_SHA", "").strip(),
                      parse_bots(os.environ.get("INPUT_BOT_PRS", DEFAULT_BOTS)),
                      parse_paths(os.environ.get("INPUT_QA_PATHS", DEFAULT_QA_PATHS)), check_name, test_check,
                      os.environ.get("INPUT_QA_TEAM", ""), os.environ.get("INPUT_RUN_URL", ""), panel_login)
        else:
            sweep(repo, token, check_name, test_check, os.environ.get("INPUT_CALLER_WORKFLOW", ""))
        return 0
    else:
        raise GateError(f"INPUT_MODE must be review, comment, ci, bot or sweep, got {mode!r}")
    if "skip" in decision:
        print(f"::notice::qa-review-gate: {decision['skip']}")
        if mode == "comment" and decision.get("pr_number"):
            reply(repo, decision["pr_number"], f"the comment did nothing: {decision['skip']}.", token)
        return 0
    qa_team, run_url = os.environ.get("INPUT_QA_TEAM", ""), os.environ.get("INPUT_RUN_URL", "")
    head = apply(decision, repo, token, qa_team, run_url, panel_login)
    for check in decision.get("checks") or [decision["check"]] if head else []:
        print(f"qa-review-gate: {check['name']} -> {check['conclusion']} on {head[:7]}")
    if mode == "bot" and any(c.get("external_id") == SCOPE_EXTERNAL_ID for c in decision.get("checks") or []):
        regraded = regrade_if_retargeted(event, repo, token, parse_paths(os.environ.get("INPUT_QA_PATHS", DEFAULT_QA_PATHS)),
                                         check_name, test_check, qa_team, run_url, panel_login)
        for check in (regraded or {}).get("checks") or []:
            print(f"qa-review-gate: {check['name']} -> {check['conclusion']} on {head[:7]} (retargeted meanwhile)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GateError as error:
        print(f"::error::qa-review-gate: {error}")
        sys.exit(1)

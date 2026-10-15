#!/usr/bin/env python3
"""Sweep GitHub organizations for indicators of a malicious-workflow campaign.

The indicators are data (a JSON file per campaign), so a new campaign needs a new
file, not new code. For every repository of every owner the sweep checks:

  registry  registered Actions workflows, which lists a workflow that ran from any
            branch, including one whose file or branch was deleted afterwards
  history   a blobless clone of every branch and tag: commit subjects, workflow file
            paths in all history, and endpoints in .github/ diffs since a date
  audit     per owner, workflow runs in the enterprise audit log over N days

Exit codes: 0 clean, 1 indicator found, 2 sweep incomplete without an indicator.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

EXIT_CLEAN = 0
EXIT_INDICATOR = 1
EXIT_INCOMPLETE = 2
RESULTS = {EXIT_CLEAN: "clean", EXIT_INDICATOR: "indicator", EXIT_INCOMPLETE: "error"}

SEP = "\x1f"
WORKFLOW_DIR = ".github/workflows/"


@dataclass(frozen=True)
class Iocs:
    campaigns: tuple[str, ...]
    history_since: str
    workflow_files: frozenset[str]
    workflow_names: frozenset[str]
    commit_messages: frozenset[str]
    endpoint_re: re.Pattern | None


@dataclass
class Report:
    findings: list[dict] = field(default_factory=list)
    errors: list[dict] = field(default_factory=list)
    repos: int = 0


def normalize_file(name: str) -> str:
    base = name.rsplit("/", 1)[-1].strip().lower()
    return base[:-5] + ".yml" if base.endswith(".yaml") else base


def normalize_text(text: str) -> str:
    return " ".join(text.split()).lower()


def load_iocs(paths: list[str]) -> Iocs:
    campaigns, since, files, names, messages, endpoints = [], [], set(), set(), set(), set()
    for path in paths:
        data = json.loads(Path(path).read_text())
        campaigns.append(data["campaign"])
        if data.get("history_since"):
            since.append(data["history_since"])
        files.update(normalize_file(f) for f in data.get("workflow_files", []))
        names.update(normalize_text(n) for n in data.get("workflow_names", []))
        messages.update(normalize_text(m) for m in data.get("commit_messages", []))
        endpoints.update(e for e in data.get("endpoints", []) if e.strip())
    endpoint_re = None
    if endpoints:
        endpoint_re = re.compile("|".join(re.escape(e) for e in sorted(endpoints)), re.IGNORECASE)
    return Iocs(
        campaigns=tuple(campaigns),
        history_since=min(since) if since else "",
        workflow_files=frozenset(files),
        workflow_names=frozenset(names),
        commit_messages=frozenset(messages),
        endpoint_re=endpoint_re,
    )


def is_workflow_file(path: str, iocs: Iocs) -> bool:
    return path.startswith(WORKFLOW_DIR) and normalize_file(path) in iocs.workflow_files


def is_workflow_name(name: str | None, iocs: Iocs) -> bool:
    return bool(name) and normalize_text(name) in iocs.workflow_names


def is_commit_message(subject: str, iocs: Iocs) -> bool:
    return normalize_text(subject) in iocs.commit_messages


def endpoint_hits(text: str, iocs: Iocs) -> list[str]:
    if iocs.endpoint_re is None:
        return []
    return sorted({m.group(0).lower() for m in iocs.endpoint_re.finditer(text)})


# --- pure checks over already-fetched data ------------------------------------


def check_registry(repo: str, workflows: list[dict], iocs: Iocs) -> list[dict]:
    findings = []
    for wf in workflows:
        path, name = wf.get("path", ""), wf.get("name", "")
        if is_workflow_file(path, iocs) or is_workflow_name(name, iocs):
            findings.append({
                "check": "registry", "repo": repo, "workflow_id": wf.get("id"),
                "name": name, "path": path, "state": wf.get("state"),
                "created_at": wf.get("created_at"),
            })
    return findings


def check_audit(owner: str, events: list[dict], iocs: Iocs) -> list[dict]:
    findings = []
    for ev in events:
        if is_workflow_name(ev.get("name"), iocs):
            findings.append({
                "check": "audit", "owner": owner, "repo": ev.get("repo"),
                "name": ev.get("name"), "event": ev.get("event"),
                "actor": ev.get("actor"), "head_branch": ev.get("head_branch"),
                "programmatic_access_type": ev.get("programmatic_access_type"),
                "workflow_run_id": ev.get("workflow_run_id"),
                "created_at": ev.get("created_at"),
            })
    return findings


def parse_subjects(out: str, repo: str, iocs: Iocs) -> list[dict]:
    findings = []
    for line in out.splitlines():
        parts = line.split(SEP)
        if len(parts) == 4 and is_commit_message(parts[3], iocs):
            findings.append({"check": "commit-message", "repo": repo, "commit": parts[0],
                             "date": parts[1], "author": parts[2], "subject": parts[3]})
    return findings


def parse_name_status(out: str, repo: str, iocs: Iocs) -> list[dict]:
    findings, commit = [], None
    for line in out.splitlines():
        if line.startswith("COMMIT" + SEP):
            _, sha, date, author, subject = (line.split(SEP) + [""] * 5)[:5]
            commit = {"commit": sha, "date": date, "author": author, "subject": subject}
            continue
        cols = line.split("\t")
        if commit is None or len(cols) < 2:
            continue
        for path in cols[1:]:
            if is_workflow_file(path, iocs):
                findings.append({"check": "workflow-file", "repo": repo, "status": cols[0],
                                 "path": path, **commit})
    return findings


def parse_patch(out: str, repo: str, iocs: Iocs) -> list[dict]:
    findings, commit, seen = [], None, set()
    for line in out.splitlines():
        if line.startswith("COMMIT" + SEP):
            _, sha, date = (line.split(SEP) + [""] * 3)[:3]
            commit = {"commit": sha, "date": date}
            continue
        if commit is None:
            continue
        for hit in endpoint_hits(line, iocs):
            if (commit["commit"], hit) not in seen:
                seen.add((commit["commit"], hit))
                findings.append({"check": "endpoint", "repo": repo, "endpoint": hit,
                                 "line": line[:300], **commit})
    return findings


# --- process helpers ----------------------------------------------------------


class SweepError(Exception):
    pass


def redact(text: str, secret: str) -> str:
    text = text.strip()
    if secret:
        text = text.replace(secret, "***")
    return text[-500:]


def git_env(token: str) -> dict:
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never")
    if token:
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        env.update({
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
            "GIT_CONFIG_VALUE_0": f"AUTHORIZATION: basic {basic}",
        })
    return env


def run(cmd: list[str], env: dict, token: str, cwd: str | None = None, timeout: int = 1800) -> str:
    try:
        proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True,
                              timeout=timeout, errors="replace")
    except subprocess.TimeoutExpired as exc:
        raise SweepError(f"{cmd[0]} {cmd[1]} timed out after {timeout}s") from exc
    if proc.returncode != 0:
        raise SweepError(f"{cmd[0]} {cmd[1]} exited {proc.returncode}: {redact(proc.stderr, token)}")
    return proc.stdout


class GitHub:
    """Thin wrapper over `gh api`; tests replace it with a fake."""

    def __init__(self, token: str):
        self.token = token
        self.env = dict(os.environ, GH_PROMPT_DISABLED="1", NO_COLOR="1")
        if token:
            self.env["GH_TOKEN"] = token

    def items(self, path: str, jq: str) -> list[dict]:
        out = run(["gh", "api", "--paginate", path, "--jq", jq], self.env, self.token)
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def repos(self, owner: str) -> list[dict]:
        return self.items(f"orgs/{owner}/repos?type=all&per_page=100",
                          ".[]|{full_name,archived,size}")

    def workflows(self, repo: str) -> list[dict]:
        return self.items(f"repos/{repo}/actions/workflows?per_page=100", ".workflows[]")

    def audit_runs(self, owner: str, day: str) -> list[dict]:
        phrase = f"action:workflows.created_workflow_run+created:{day}"
        return self.items(f"orgs/{owner}/audit-log?phrase={phrase}&per_page=100", ".[]")


def scan_history(repo: str, url: str, workdir: str, since: str, iocs: Iocs, token: str) -> list[dict]:
    env = git_env(token)
    dest = os.path.join(workdir, repo.replace("/", "__") + ".git")
    try:
        run(["git", "clone", "--bare", "--filter=blob:none", "--quiet", url, dest], env, token)
        if not run(["git", "for-each-ref", "--count=1", "refs/heads", "refs/tags"], env, token, cwd=dest).strip():
            return []
        findings = parse_subjects(run(
            ["git", "log", "--all", f"--format=%H{SEP}%cI{SEP}%an <%ae>{SEP}%s"],
            env, token, cwd=dest), repo, iocs)
        findings += parse_name_status(run(
            ["git", "log", "--all", f"--format=COMMIT{SEP}%H{SEP}%cI{SEP}%an <%ae>{SEP}%s",
             "--name-status", "--", WORKFLOW_DIR], env, token, cwd=dest), repo, iocs)
        if iocs.endpoint_re is not None:
            log = ["git", "log", "--all", "-p", f"--format=COMMIT{SEP}%H{SEP}%cI"]
            if since:
                log.append(f"--since={since}")
            findings += parse_patch(run(log + ["--", ".github/"], env, token, cwd=dest), repo, iocs)
        return findings
    finally:
        shutil.rmtree(dest, ignore_errors=True)


# --- orchestration ------------------------------------------------------------


def sweep_repo(gh: GitHub, repo: str, args, iocs: Iocs) -> tuple[list[dict], list[dict]]:
    findings, errors = [], []
    try:
        findings += check_registry(repo, gh.workflows(repo), iocs)
    except SweepError as exc:
        # Actions disabled or a security-advisory fork: nothing can have run there.
        if "404" not in str(exc):
            errors.append({"stage": "registry", "repo": repo, "error": str(exc)})
    try:
        url = args.clone_url.format(repo=repo)
        findings += scan_history(repo, url, args.workdir, args.since, iocs, gh.token)
    except SweepError as exc:
        errors.append({"stage": "history", "repo": repo, "error": str(exc)})
    return findings, errors


def audit_days(today: datetime, days: int) -> list[str]:
    return [(today - timedelta(days=n)).strftime("%Y-%m-%d") for n in range(days)]


def sweep(gh: GitHub, args, iocs: Iocs, today: datetime | None = None) -> Report:
    report = Report()
    today = today or datetime.now(timezone.utc)
    for owner in args.owners:
        try:
            repos = [r["full_name"] for r in gh.repos(owner) if args.include_archived or not r.get("archived")]
        except SweepError as exc:
            report.errors.append({"stage": "list-repos", "owner": owner, "error": str(exc)})
            continue
        report.repos += len(repos)
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for findings, errors in pool.map(lambda r: sweep_repo(gh, r, args, iocs), repos):
                report.findings += findings
                report.errors += errors
        for day in audit_days(today, args.audit_days):
            try:
                report.findings += check_audit(owner, gh.audit_runs(owner, day), iocs)
            except SweepError as exc:
                report.errors.append({"stage": "audit", "owner": owner, "day": day, "error": str(exc)})
    return report


def exit_code(report: Report) -> int:
    if report.findings:
        return EXIT_INDICATOR
    return EXIT_INCOMPLETE if report.errors else EXIT_CLEAN


def summary_markdown(report: Report, iocs: Iocs, owners: list[str], code: int) -> str:
    lines = [f"## Workflow IOC sweep: {RESULTS[code]}", "",
             f"Campaigns: {', '.join(iocs.campaigns)}. Owners: {', '.join(owners)}. "
             f"Repositories: {report.repos}. Findings: {len(report.findings)}. "
             f"Errors: {len(report.errors)}.", ""]
    if report.findings:
        lines += ["| Check | Repo | Detail |", "|---|---|---|"]
        for f in report.findings:
            detail = f.get("path") or f.get("subject") or f.get("endpoint") or f.get("name") or ""
            lines.append(f"| {f['check']} | {f.get('repo', '')} | `{detail}` |")
        lines.append("")
    if report.errors:
        lines += ["| Stage | Target | Error |", "|---|---|---|"]
        for e in report.errors:
            target = e.get("repo") or e.get("owner", "")
            lines.append(f"| {e['stage']} | {target} | {e['error'][:200].replace('|', '/')} |")
    return "\n".join(lines) + "\n"


def parse_args(argv: list[str]) -> argparse.Namespace:
    here = Path(__file__).resolve().parent.parent
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--owners", nargs="+", required=True)
    p.add_argument("--iocs", action="append", default=[], help="indicator JSON file, repeatable")
    p.add_argument("--since", default="", help="endpoint diff window start, default from the IOC file")
    p.add_argument("--audit-days", type=int, default=0)
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--include-archived", action="store_true")
    p.add_argument("--report", default="ioc-sweep-report.json")
    p.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    p.add_argument("--workdir", default="")
    p.add_argument("--clone-url", default="https://github.com/{repo}.git")
    args = p.parse_args(argv)
    if not args.iocs:
        args.iocs = [str(here / "iocs" / "ghostaction.json")]
    return args


def write_output(code: int, report_path: str) -> None:
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"result={RESULTS[code]}\nreport-path={report_path}\n")


def main(argv: list[str] | None = None, gh: GitHub | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        iocs = load_iocs(args.iocs)
    except (OSError, ValueError, KeyError) as exc:
        print(f"::error::cannot load indicators: {exc}", file=sys.stderr)
        write_output(EXIT_INCOMPLETE, args.report)
        return EXIT_INCOMPLETE
    args.since = args.since or iocs.history_since
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    gh = gh or GitHub(token)
    owned_workdir = not args.workdir
    args.workdir = args.workdir or tempfile.mkdtemp(prefix="ioc-sweep-")
    try:
        report = sweep(gh, args, iocs)
    finally:
        if owned_workdir:
            shutil.rmtree(args.workdir, ignore_errors=True)
    code = exit_code(report)
    Path(args.report).write_text(json.dumps({
        "result": RESULTS[code], "campaigns": iocs.campaigns, "owners": args.owners,
        "since": args.since, "audit_days": args.audit_days, "repositories": report.repos,
        "findings": report.findings, "errors": report.errors,
    }, indent=2) + "\n")
    md = summary_markdown(report, iocs, args.owners, code)
    if args.summary:
        with open(args.summary, "a") as fh:
            fh.write(md)
    print(md)
    for f in report.findings:
        print(f"::error::{f['check']} indicator in {f.get('repo', '')}: "
              f"{f.get('path') or f.get('subject') or f.get('endpoint') or f.get('name')}")
    write_output(code, args.report)
    return code


if __name__ == "__main__":
    sys.exit(main())

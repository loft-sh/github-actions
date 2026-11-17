"""One-shot backport approval from trusted workflow_run completion events."""

import json
import os
import re
import subprocess
from pathlib import Path
from urllib.parse import quote


class Skip(Exception):
    """An expected policy miss, reevaluated on the next completion event."""


class GitHub:
    def __init__(self, token):
        if not token:
            raise ValueError("missing GitHub token")
        self.env = {**os.environ, "GH_TOKEN": token}

    def api(self, path, payload=None, paginate=False):
        args = ["gh", "api", path]
        if paginate:
            args += ["--paginate", "--slurp"]
        if payload is not None:
            args += ["--input", "-"]
        result = subprocess.run(
            args, input=json.dumps(payload) if payload is not None else None,
            env=self.env, text=True, capture_output=True, timeout=120, check=True,
        )
        data = json.loads(result.stdout)
        if isinstance(data, dict) and data.get("errors"):
            raise ValueError("GraphQL read failed")
        return data

    def items(self, path, key=None):
        pages = self.api(path, paginate=True)
        return [item for page in pages for item in (page[key] if key else page)]


PROTECTION_QUERY = """
query($owner: String!, $name: String!, $ref: String!) {
  repository(owner: $owner, name: $name) {
    ref(qualifiedName: $ref) {
      branchProtectionRule {
        requiresStatusChecks
        requiredStatusChecks { context app { databaseId } }
      }
    }
  }
}
"""


def required_checks(api, repo, base):
    """Union classic branch protection with all enforced repository/org rules."""
    owner, name = repo.split("/")
    data = api.api("graphql", {"query": PROTECTION_QUERY, "variables": {
        "owner": owner, "name": name, "ref": f"refs/heads/{base}",
    }})
    ref = data["data"]["repository"]["ref"]
    if ref is None:
        raise Skip("base branch is unavailable")
    checks = set()
    classic = ref["branchProtectionRule"]
    if classic and classic["requiresStatusChecks"]:
        checks.update((c["context"], (c["app"] or {}).get("databaseId"))
                      for c in classic["requiredStatusChecks"])
    rules = api.items(f"repos/{repo}/rules/branches/{quote(base, safe='')}?per_page=100")
    for rule in rules:
        if rule["type"] == "workflows":
            raise Skip("required workflows need a separate verified gate")
        if rule["type"] == "required_status_checks":
            checks.update((c["context"], c.get("integration_id"))
                          for c in rule["parameters"]["required_status_checks"])
    if not checks:
        raise Skip("no required checks configured; refusing an empty gate")
    return checks


def rank(check):
    # Same information ordering as wait-for-ci.sh. A skipped/cancelled run
    # must not hide a failure, and a pending rerun must not reuse old success.
    weight = (3 if check["status"] != "completed" else
              1 if check["conclusion"] in ("skipped", "cancelled") else 2)
    return weight, check.get("started_at") or "", check["id"]


def check_signals(api, repo, sha):
    runs = api.items(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100", "check_runs")
    statuses = api.items(f"repos/{repo}/commits/{sha}/statuses?per_page=100")
    return runs, statuses


def green(requirements, runs, statuses):
    for name, app_id in requirements:
        matching = [c for c in runs if c["name"] == name
                    and (app_id in (None, -1) or c["app"]["id"] == app_id)]
        legacy = [s for s in statuses if s["context"] == name]
        if not matching and not legacy:
            raise Skip(f"required check {name!r} has not registered")
        if matching:
            check = max(matching, key=rank)
            if (check["status"] != "completed"
                    or check["conclusion"] not in ("success", "neutral", "skipped")):
                raise Skip(f"required check {name!r} is pending or unsuccessful")
        # A status cannot satisfy an app-bound check; if both APIs publish the
        # same required name, both must pass, as GitHub branch protection does.
        if legacy:
            if app_id not in (None, -1) and not matching:
                raise Skip(f"required check {name!r} is missing its configured app")
            if max(legacy, key=lambda s: s["id"])["state"] != "success":
                raise Skip(f"required status {name!r} is pending or unsuccessful")


def eligible(pr, repo, sha, authors, skip_labels):
    return (
        pr["state"] == "open" and not pr["draft"]
        and pr["head"]["repo"] is not None
        and pr["head"]["repo"]["full_name"] == repo
        and pr["base"]["repo"]["full_name"] == repo
        and pr["head"]["sha"] == sha
        and pr["head"]["ref"].startswith("backport/")
        and pr["user"]["login"] in authors
        and not any(label["name"].lower() in skip_labels for label in pr["labels"])
    )


def gate(api, repo, pr):
    if pr["mergeable"] is not True:
        raise Skip("mergeability is unknown or conflicted; rerun after resolving")
    requirements = required_checks(api, repo, pr["base"]["ref"])
    green(requirements, *check_signals(api, repo, pr["head"]["sha"]))
    # GitHub prefers test-merge results when they exist. Never fall back to a
    # green head if the current test merge has published non-green checks.
    merge_sha = pr.get("merge_commit_sha")
    if merge_sha and merge_sha != pr["head"]["sha"]:
        runs, statuses = check_signals(api, repo, merge_sha)
        if runs or statuses:
            green(requirements, runs, statuses)


def evaluate(reader, approver, repo, event, authors, skip_labels):
    run = event["workflow_run"]
    if (event["action"] != "completed" or run["status"] != "completed"
            or run["event"] != "pull_request"
            or run["head_repository"]["full_name"] != repo
            or not run["head_branch"].startswith("backport/")):
        return
    sha = run["head_sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("invalid completion SHA")
    # Do not trust workflow_run.pull_requests, which can be empty on reruns.
    # Resolve the exact completed commit, then read current PR policy from API.
    candidates = reader.items(f"repos/{repo}/commits/{sha}/pulls?per_page=100")
    for candidate in candidates:
        number = candidate["number"]
        if type(number) is not int or number <= 0:
            raise ValueError("invalid PR number")
        path = f"repos/{repo}/pulls/{number}"
        pr = reader.api(path)
        if not eligible(pr, repo, sha, authors, skip_labels):
            continue
        try:
            gate(reader, repo, pr)
            login = approver.api("user")["login"]
            if login == pr["user"]["login"]:
                raise Skip("approver is the PR author")
            reviews = approver.items(f"{path}/reviews?per_page=100")
            own = [r for r in reviews if r["user"]["login"] == login
                   and r["state"] != "COMMENTED" and r["state"] != "PENDING"]
            if own:
                latest = max(own, key=lambda r: r["id"])
                if latest["state"] == "APPROVED" and latest["commit_id"] == sha:
                    print(f"PR #{number}: already approved at {sha}")
                    continue
            current = reader.api(path)
            if (not eligible(current, repo, sha, authors, skip_labels)
                    or current["base"]["ref"] != pr["base"]["ref"]
                    or current["base"]["sha"] != pr["base"]["sha"]):
                raise Skip("PR eligibility, head or base changed during evaluation")
            gate(reader, repo, current)
            # commit_id prevents a racing push receiving approval for its new SHA.
            review = approver.api(f"{path}/reviews", {
                "commit_id": sha, "event": "APPROVE",
                "body": "Approved by the shared backport workflow after all required checks passed.",
            })
            if review["state"] != "APPROVED" or review["commit_id"] != sha:
                raise ValueError("could not verify approval")
            print(f"PR #{number}: approved tested commit {sha}")
        except Skip as exc:
            print(f"PR #{number}: skip: {exc}")


def main():
    try:
        if os.environ["GITHUB_EVENT_NAME"] != "workflow_run":
            raise ValueError("completion mode requires workflow_run")
        repo = os.environ["GITHUB_REPOSITORY"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("invalid repository")
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        evaluate(GitHub(os.environ["CI_READ_TOKEN"]), GitHub(os.environ["APPROVER_TOKEN"]),
                 repo, event, set(os.environ["TRUSTED_AUTHORS"].split(",")),
                 {s.strip().lower() for s in os.environ.get("SKIP_LABELS", "").split(",") if s.strip()})
    except Exception as exc:
        # Never print an API body, token, or attacker-controlled workflow command.
        print(f"::warning::Completion approval skipped ({type(exc).__name__}); "
              "inspect required checks and token permissions, then rerun this workflow.")


if __name__ == "__main__":
    main()

"""Bounded, opt-in retries. All policy reads run again before the single write."""

import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


class PolicySkip(Exception):
    pass


@dataclass(frozen=True)
class Config:
    repository: str
    run_id: int
    run_attempt: int
    workflow_ids: frozenset[int]
    max_retries: int = 3
    enabled: bool = False
    dry_run: bool = True

    def validate(self):
        if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", self.repository)
                or self.repository.split("/")[-1] in (".", "..")):
            raise ValueError("repository must be owner/name")
        ids = [self.run_id, self.run_attempt, *self.workflow_ids]
        if not self.workflow_ids or any(type(x) is not int or x <= 0 for x in ids):
            raise ValueError("run, attempt and workflow IDs must be positive integers")
        if type(self.max_retries) is not int or not 0 <= self.max_retries <= 3:
            raise ValueError("max-retries must be in 0..3")
        if type(self.enabled) is not bool or type(self.dry_run) is not bool:
            raise ValueError("enabled and dry-run must be true or false")


REVIEW_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      state isDraft headRefOid reviewDecision
      headRepository { nameWithOwner }
      baseRepository { nameWithOwner }
      author { login }
      latestOpinionatedReviews(first: 100, writersOnly: true) {
        nodes { state commit { oid } author { login __typename } }
        pageInfo { hasNextPage }
      }
    }
  }
}
"""


class GitHub:
    """Use the runner's gh auth. Never log API errors, which can carry private data."""

    @staticmethod
    def _call(args, payload=None, parse=True):
        result = subprocess.run(
            ["gh", "api", *args],
            input=json.dumps(payload) if payload is not None else None,
            text=True, capture_output=True, timeout=30, check=False,
        )
        if result.returncode:
            raise RuntimeError("GitHub API request failed; check token permissions and run logs")
        return json.loads(result.stdout) if parse else None

    def get(self, path):
        return self._call([path])

    def post(self, path):
        # A lost response is ambiguous. Do not retry this request automatically.
        return self._call(["--method", "POST", path], parse=False)

    def graphql(self, query, variables):
        data = self._call(["graphql", "--input", "-"], {"query": query, "variables": variables})
        if data.get("errors"):
            raise RuntimeError("GitHub GraphQL query failed")
        return data


def require(condition, reason):
    if not condition:
        raise PolicySkip(reason)


def snapshot(config, api):
    repo = config.repository
    run = api.get(f"repos/{repo}/actions/runs/{config.run_id}")
    require(type(run["id"]) is int and run["id"] == config.run_id, "wrong_run")
    require(run["repository"]["full_name"] == repo, "wrong_repository")
    require(run["head_repository"]["full_name"] == repo, "fork")
    require(run["event"] == "pull_request", "unsupported_event")
    require(type(run["workflow_id"]) is int and run["workflow_id"] in config.workflow_ids,
            "workflow_not_allowed")
    require(type(run["run_attempt"]) is int and run["run_attempt"] == config.run_attempt,
            "stale_attempt")
    require(run["status"] == "completed" and run["conclusion"] == "failure", "not_failed")
    sha = run["head_sha"]
    require(isinstance(sha, str) and re.fullmatch(r"[a-f0-9]{40}", sha), "invalid_head")
    require(len(run["pull_requests"]) == 1, "ambiguous_pr")
    number = run["pull_requests"][0]["number"]
    require(type(number) is int and number > 0, "invalid_pr")
    owner, name = repo.split("/")
    data = api.graphql(REVIEW_QUERY, {"owner": owner, "name": name, "number": number})
    require(not data.get("errors"), "review_query_failed")
    pr = data["data"]["repository"]["pullRequest"]
    require(pr["state"] == "OPEN" and pr["isDraft"] is False, "pr_not_ready")
    require(pr["headRepository"]["nameWithOwner"] == repo
            and pr["baseRepository"]["nameWithOwner"] == repo, "fork")
    require(pr["headRefOid"] == sha, "head_changed")
    require(pr["reviewDecision"] == "APPROVED", "approval_required")
    reviews = pr["latestOpinionatedReviews"]
    require(reviews["pageInfo"]["hasNextPage"] is False, "too_many_reviews")
    require(all(r["state"] != "CHANGES_REQUESTED" for r in reviews["nodes"]),
            "changes_requested")
    require(any(r["state"] == "APPROVED" and r["commit"]["oid"] == sha
                and r["author"]["__typename"] == "User"
                and r["author"]["login"] != pr["author"]["login"]
                for r in reviews["nodes"]), "current_human_approval_required")

    # Do not revive superseded runs. Pagination is bounded and fails closed.
    found = False
    for page in range(1, 11):
        path = (f"repos/{repo}/actions/workflows/{run['workflow_id']}/runs"
                f"?event=pull_request&head_sha={sha}&per_page=100&page={page}")
        runs = api.get(path)["workflow_runs"]
        require(isinstance(runs, list), "invalid_runs")
        for other in runs:
            require(type(other["id"]) is int, "invalid_runs")
            # A missing association cannot prove a different PR. Stop conservatively.
            require(other["head_sha"] == sha and other["workflow_id"] == run["workflow_id"],
                    "invalid_runs")
            require(isinstance(other["pull_requests"], list) and other["pull_requests"],
                    "unassociated_run")
            same_pr = any(p["number"] == number for p in other["pull_requests"])
            require(not same_pr or other["id"] <= config.run_id, "superseded_run")
            found |= same_pr and other["id"] == config.run_id
        if len(runs) < 100:
            break
    else:
        raise PolicySkip("too_many_runs")
    require(found, "run_not_listed")
    return {"head_sha": sha, "pr_number": number, "workflow_id": run["workflow_id"]}


def evaluate(config, api):
    config.validate()
    result = {"outcome": "disabled", "reason": "enable_explicitly", "head_sha": "",
              "run_url": f"https://github.com/{config.repository}/actions/runs/{config.run_id}",
              "retries_used": config.run_attempt - 1}
    if not config.enabled:
        return result
    try:
        first = snapshot(config, api)
        result.update(first)
        if config.run_attempt - 1 >= config.max_retries:
            diagnosis = dict(first, version=1, repository=config.repository,
                             run_id=config.run_id, run_attempt=config.run_attempt,
                             run_url=result["run_url"], reason="retry_budget_exhausted")
            return dict(result, outcome="exhausted", reason="author_diagnosis_required",
                        diagnosis=json.dumps(diagnosis, sort_keys=True))
        second = snapshot(config, api)
        require(first == second, "state_changed")
        if config.dry_run:
            return dict(result, outcome="would_retry", reason="dry_run")
        api.post(f"repos/{config.repository}/actions/runs/{config.run_id}/rerun-failed-jobs")
        return dict(result, outcome="retried", reason="failed_jobs_requested")
    except PolicySkip as exc:
        return dict(result, outcome="skipped", reason=str(exc))
    except (KeyError, TypeError, ValueError, RuntimeError, subprocess.SubprocessError):
        return dict(result, outcome="error", reason="verify_api_access_and_state")


def boolean(name, default):
    value = os.environ.get(name, default)
    if value not in ("true", "false"):
        raise ValueError(f"{name} must be true or false")
    return value == "true"


def main():
    try:
        config = Config(
            repository=os.environ["GITHUB_REPOSITORY"],
            run_id=int(os.environ["INPUT_RUN_ID"]),
            run_attempt=int(os.environ["INPUT_RUN_ATTEMPT"]),
            workflow_ids=frozenset(int(x.strip()) for x in os.environ["INPUT_WORKFLOW_IDS"].split(",")),
            max_retries=int(os.environ.get("INPUT_MAX_RETRIES", "3")),
            enabled=boolean("INPUT_ENABLED", "false"),
            dry_run=boolean("INPUT_DRY_RUN", "true"),
        )
        result = evaluate(config, GitHub())
    except (KeyError, ValueError):
        result = {"outcome": "error", "reason": "invalid_configuration"}
    # Only fixed vocabulary, validated IDs/SHA and constructed URLs reach outputs.
    print(json.dumps(result, sort_keys=True))
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
            summary.write(f"CI retry: {result['outcome']} ({result['reason']}).\n\n")
            if result.get("run_url"):
                summary.write(f"[Workflow run]({result['run_url']})\n\n")
            if result["outcome"] in ("exhausted", "error"):
                summary.write("PR author: inspect the failed jobs and diagnose the cause before another run.\n")
    # Advisory automation does not turn an unrelated PR check red.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

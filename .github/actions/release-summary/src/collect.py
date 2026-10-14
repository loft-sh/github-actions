#!/usr/bin/env python3
"""release-summary: decide whether to summarize, then collect the merged PRs
between the previous tag and the release tag.

Runs inside a checkout of the released repository (full history and tags).
Writes two files under RUNNER_TEMP:

  release-summary-input.json  what the AI step reads (descriptions, paths, ids)
  release-summary-prs.json    what render.py reads (PR numbers, urls, Linear ids)

The action must never fail a release, so every path, including an
unexpected exception, ends with exit 0. A skip writes proceed=false and a
one-line reason that names the remedy.

Env:
  VERSION             release tag (required)
  PREVIOUS_TAG        optional override for the comparison base
  REPOSITORY          owner/name
  GH_TOKEN            token with read access to the repository's PRs
  HAS_ANTHROPIC_KEY   "true" when an Anthropic key was passed
  HAS_SLACK_TOKEN     "true" when a Slack bot token was passed
  CHANNEL_ID          Slack channel the banner went to
  THREAD_TS           banner message ts, or its Slack link, to reply under
  DRY_RUN             "true" to collect and summarize without posting
"""
from __future__ import annotations

import fnmatch
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Tags that never get a #product-releases banner, so they make a useless
# comparison base. loft-enterprise alone carries 77 -next tags.
TAG_MATCH = "v*"
TAG_EXCLUDE = "*-next*"

COMMIT_LIMIT = 500
SLACK_TS = re.compile(r"\d{9,}\.\d{6}")
SLACK_LINK = re.compile(r"/p(\d{10})(\d{6})(?:\D|$)")
GRAPHQL_BATCH = 40
GRAPHQL_ATTEMPTS = 3
# URLError, timeouts and resets (RemoteDisconnected, IncompleteRead) are all
# one family: the request may succeed on another try.
NETWORK_ERRORS = (OSError, http.client.HTTPException)
PATHS_PER_PR = 30
# Fits comfortably inside the model's context; the env var limit does not
# apply because ai-step reads this through input-file.
MAX_INPUT_BYTES = 400_000
MIN_BODY_CHARS = 400

# An id is uppercase and not followed by "-<digits>": "GO-2026-5932" is a Go
# advisory, not issue 2026 of team GO. Only the closing keywords are
# case-insensitive, so "related to helm-3" names no issue.
LINEAR_KEY = r"[A-Z][A-Z0-9]{1,9}-\d+\b(?!-\d)"
LINEAR_ID = r"(?<![\w-])" + LINEAR_KEY
# BUMP: branches such as "bump-3/golang", which look exactly like team-n.
NOT_LINEAR = {"CVE", "GHSA", "RFC", "ISO", "UTF", "SHA", "TLS", "X509", "BUMP"}
ID_SEP = r"(?:\s*,\s*(?:(?i:and)\s+)?|\s+(?i:and)\s+|\s*&\s*)"
# A closing keyword takes the whole comma or "and" separated list after it.
CLOSING = re.compile(
    r"\b(?i:close[sd]?|fix(?:e[sd])?|resolve[sd]?|part of|refs?|references?|related to)"
    r"\s*:?\s+(" + LINEAR_ID + r"(?:" + ID_SEP + LINEAR_ID + r")*)")
LINEAR_URL = re.compile(r"linear\.app/[\w-]+/issue/(" + LINEAR_KEY + r")", re.I)
# Leading "[release-4.12]" backport tags and "[ENG-1]" groups.
TITLE_BRACKETS = re.compile(r"\s*((?:\[[^\]]*\]\s*)*)")
# Conventional-commit scope: "fix(ENGCP-1606)!: x".
TITLE_SCOPE = re.compile(r"\w+\(([^)]*)\)!?:")
BRANCH_TEAM_N = re.compile(r"([a-z][a-z0-9]{1,9}-\d+)", re.I)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)


def emit(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as f:
        f.write(f"{key}={value}\n")


def skip(reason: str) -> None:
    print(f"::warning::release-summary: {reason}")
    emit("proceed", "false")
    emit("reason", reason.replace("\n", " "))
    sys.exit(0)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True,
                          text=True).stdout.strip()


def tag_exists(tag: str) -> bool:
    return subprocess.run(["git", "rev-parse", "--verify", "-q",
                           f"refs/tags/{tag}"], capture_output=True).returncode == 0


def is_shallow() -> bool:
    return git("rev-parse", "--is-shallow-repository") == "true"


SEMVER = re.compile(r"v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?")


def semver_key(tag: str) -> tuple | None:
    """Sort key in semver precedence order, None for a tag that is not semver.
    A prerelease sorts below its release and rc.10 above rc.9."""
    m = SEMVER.fullmatch(tag)
    if not m:
        return None
    major, minor, patch, pre = m.groups()
    # Numeric identifiers compare as numbers and sort below alphanumeric ones;
    # (kind, number, text) keeps the three tuple positions comparable.
    ids = tuple((0, int(i), "") if i.isdigit() else (1, 0, i)
                for i in pre.split(".")) if pre else ()
    return (int(major), int(minor), int(patch), 0 if pre else 1, ids)


def release_tags_at(tag: str) -> list[str]:
    """TAG_MATCH tags, minus TAG_EXCLUDE, on the commit tag points at."""
    out = git("tag", "--list", TAG_MATCH, "--points-at", f"refs/tags/{tag}^{{commit}}")
    return [t for t in out.splitlines() if not fnmatch.fnmatchcase(t, TAG_EXCLUDE)]


def nearest_below(version: str, tags: list[str]) -> str:
    """The semver-highest of tags that sorts below version, or ''."""
    limit = semver_key(version)
    if limit is None:
        return ""
    below = [(key, t) for t in tags
             if t != version and (key := semver_key(t)) is not None and key < limit]
    return max(below)[1] if below else ""


def resolve_previous_tag(version: str, override: str) -> str:
    """The override when given, else the nearest non -next tag before version.
    A release is cut from the commit of its last rc, so tags on version's own
    commit come first; `describe version^` steps past all of them."""
    if override:
        if not tag_exists(override):
            skip(f"previous tag '{override}' is not in the checkout; pass an "
                 "existing tag or leave previous-tag empty to derive it")
        return override
    shared = nearest_below(version, release_tags_at(version))
    if shared:
        return shared
    try:
        found = git("describe", "--tags", "--abbrev=0", f"--match={TAG_MATCH}",
                    f"--exclude={TAG_EXCLUDE}", f"{version}^")
    except subprocess.CalledProcessError:
        skip(f"no earlier {TAG_MATCH} tag is reachable from {version}, so there "
             "is nothing to compare against; pass previous-tag to set one")
        return ""
    # describe picks arbitrarily among tags sharing a commit (v4.12.0 or its
    # v4.12.0-rc.12), so settle that by semver too.
    return nearest_below(version, release_tags_at(found)) or found


def list_commits(prev: str, version: str) -> list[tuple[str, str]]:
    out = git("log", "--first-parent", "--format=%H%x1f%s", f"{prev}..{version}")
    commits = [tuple(line.split("\x1f", 1)) for line in out.splitlines() if line]
    if len(commits) > COMMIT_LIMIT:
        print(f"::warning::release-summary: {len(commits)} commits between "
              f"{prev} and {version}, summarizing the newest {COMMIT_LIMIT}")
        commits = commits[:COMMIT_LIMIT]
    return commits


def title_ids(title: str) -> list[str]:
    """Ids a title names up front: in a leading [..] group (a "[release-4.12]"
    backport tag may come first), right after those groups ("ENG-12838 redfish
    explorer"), or in a conventional-commit scope ("fix(ENGCP-1606): x")."""
    brackets = TITLE_BRACKETS.match(title)
    found = re.findall(LINEAR_ID, brackets.group(1))
    rest = title[brackets.end():]
    lead = re.match(r"\[?(" + LINEAR_ID + r")", rest)
    if lead:
        found.append(lead.group(1))
    scope = TITLE_SCOPE.match(rest)
    if scope:
        found.extend(re.findall(LINEAR_ID, scope.group(1)))
    return found


def branch_ids(branch: str) -> list[str]:
    """The id a branch named for an issue carries: only a first path segment
    that is exactly team-n, as in "devops-1641/slug"."""
    m = BRANCH_TEAM_N.fullmatch((branch or "").split("/", 1)[0])
    return [m.group(1).upper()] if m else []


def linear_ids(title: str, body: str, branch: str) -> list[str]:
    """Linear ids a PR names: title, branch, then closing keywords and links
    in the body. Ordered, deduplicated, without ids that are not issues."""
    body = body or ""
    found = title_ids(title or "") + branch_ids(branch)
    for m in CLOSING.finditer(body):
        found.extend(re.findall(LINEAR_ID, m.group(1)))
    found.extend(i.upper() for i in LINEAR_URL.findall(body))
    seen: list[str] = []
    for i in found:
        if i.split("-")[0] not in NOT_LINEAR and i not in seen:
            seen.append(i)
    return seen


def clean_body(body: str) -> str:
    """Drop PR-template comments and runs of blank lines."""
    body = HTML_COMMENT.sub("", body or "")
    return re.sub(r"\n{3,}", "\n\n", body).strip()


PR_FIELDS = """
number title body url headRefName mergedAt additions deletions changedFiles
author { login }
labels(first: 10) { nodes { name } }
files(first: %d) { nodes { path } }
""" % PATHS_PER_PR


def retryable_http(err: urllib.error.HTTPError) -> bool:
    """429 and 5xx pass on their own. A 403 only when GitHub says it is a rate
    limit (Retry-After, an empty X-RateLimit-Remaining, or the secondary limit
    message). Any other 4xx, a bad token or a missing repository, would answer
    the same on every try."""
    if err.code == 429 or err.code >= 500:
        return True
    if err.code != 403:
        return False
    headers = err.headers
    if headers is not None and (headers.get("Retry-After")
                                or headers.get("X-RateLimit-Remaining") == "0"):
        return True
    try:
        return b"rate limit" in err.read().lower()
    except NETWORK_ERRORS:
        return False


def usable_partial(payload: dict) -> bool:
    """GitHub answers a batch alias that does not resolve, such as a (#N)
    subject naming an issue instead of a PR, with a null node plus a NOT_FOUND
    error, and still fills in the rest. That is usable unless the root field
    itself is null: a repository the token cannot see is a real failure."""
    errors = payload.get("errors") or []
    data = payload.get("data")
    return (bool(errors) and isinstance(data, dict) and bool(data)
            and all(v is not None for v in data.values())
            and all(isinstance(e, dict) and e.get("type") == "NOT_FOUND" for e in errors))


def graphql(query: str, variables: dict, token: str) -> dict:
    url = os.environ.get("GITHUB_GRAPHQL_URL", "https://api.github.com/graphql")
    data = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"bearer {token}",
        "Content-Type": "application/json",
    })
    last = None
    for attempt in range(GRAPHQL_ATTEMPTS):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = json.load(resp)
            if payload.get("errors") and not usable_partial(payload):
                raise RuntimeError(f"GraphQL errors: {payload['errors']}")
            return payload["data"]
        except urllib.error.HTTPError as e:
            if not retryable_http(e):
                raise RuntimeError(
                    f"GraphQL request failed with HTTP {e.code} {e.reason}; check "
                    "that github-token is valid and can read the repository") from e
            last = e
        except (RuntimeError, *NETWORK_ERRORS) as e:
            last = e
        if attempt < GRAPHQL_ATTEMPTS - 1:
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"GraphQL request failed after {GRAPHQL_ATTEMPTS} attempts: {last}")


def fetch_prs(repository: str, shas: list[str], token: str) -> dict[str, dict | None]:
    """Map each commit sha to the merged PR that brought it in, or None.
    Squash, rebase and merge commits all resolve through associatedPullRequests;
    11 of the 25 commits in loft-enterprise v5.0.0-alpha.2 carry no (#N)."""
    owner, name = repository.split("/", 1)
    result: dict[str, dict | None] = {}
    for start in range(0, len(shas), GRAPHQL_BATCH):
        batch = shas[start:start + GRAPHQL_BATCH]
        parts = [
            f'c{i}: object(oid: "{sha}") {{ ... on Commit {{ '
            f"associatedPullRequests(first: 5) {{ nodes {{ {PR_FIELDS} }} }} }} }}"
            for i, sha in enumerate(batch)
        ]
        query = ("query($owner: String!, $name: String!) { repository(owner: $owner, "
                 "name: $name) { " + " ".join(parts) + " } }")
        repo = graphql(query, {"owner": owner, "name": name}, token)["repository"]
        for i, sha in enumerate(batch):
            node = repo.get(f"c{i}") or {}
            prs = (node.get("associatedPullRequests") or {}).get("nodes") or []
            merged = [p for p in prs if p and p.get("mergedAt")]
            result[sha] = merged[0] if merged else None
    return result


SUBJECT_PR = re.compile(r"\(#(\d+)\)$")


def fetch_by_number(repository: str, numbers: list[int], token: str) -> dict[int, dict]:
    """Merged PRs by number, for commits whose subject names a PR that
    associatedPullRequests does not return (seen on loft-enterprise #8136)."""
    owner, name = repository.split("/", 1)
    found: dict[int, dict] = {}
    for start in range(0, len(numbers), GRAPHQL_BATCH):
        batch = numbers[start:start + GRAPHQL_BATCH]
        parts = [f"p{n}: pullRequest(number: {n}) {{ {PR_FIELDS} }}" for n in batch]
        query = ("query($owner: String!, $name: String!) { repository(owner: $owner, "
                 "name: $name) { " + " ".join(parts) + " } }")
        repo = graphql(query, {"owner": owner, "name": name}, token)["repository"]
        for n in batch:
            pr = repo.get(f"p{n}")
            if pr and pr.get("mergedAt"):
                found[n] = pr
    return found


def pr_record(pr: dict) -> dict:
    title = pr.get("title") or ""
    body = clean_body(pr.get("body") or "")
    return {
        "number": pr["number"],
        "url": pr.get("url", ""),
        "title": title,
        "author": (pr.get("author") or {}).get("login", ""),
        "labels": [n["name"] for n in (pr.get("labels") or {}).get("nodes") or []],
        "linear": linear_ids(title, pr.get("body") or "", pr.get("headRefName") or ""),
        "additions": pr.get("additions", 0),
        "deletions": pr.get("deletions", 0),
        "changed_files": pr.get("changedFiles", 0),
        "paths": [n["path"] for n in (pr.get("files") or {}).get("nodes") or []],
        "body": body,
    }


def fit_budget(doc: dict, limit: int = MAX_INPUT_BYTES) -> dict:
    """Trim PR bodies evenly until the document fits. Titles, paths and ids
    always survive, so even a huge range still gets a summary."""
    prs = doc["pull_requests"]
    if not prs or len(json.dumps(doc)) <= limit:
        return doc
    cap = max(MIN_BODY_CHARS, limit // len(prs))
    while True:
        for pr in prs:
            if len(pr["body"]) > cap:
                pr["body"] = pr["body"][:cap] + " [truncated]"
        if len(json.dumps(doc)) <= limit or cap <= MIN_BODY_CHARS:
            break
        cap = max(MIN_BODY_CHARS, cap // 2)
    if len(json.dumps(doc)) > limit:
        for pr in prs:
            pr["body"] = ""
        print("::warning::release-summary: input still over budget after "
              "trimming, summarizing from titles and paths only")
    return doc


def thread_ts(value: str) -> str:
    """Message ts from a ts or a Slack message link (Copy link). A link to a
    reply carries its thread's ts in the thread_ts query parameter. Empty when
    neither form matches."""
    value = value.strip()
    if SLACK_TS.fullmatch(value):
        return value
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(value).query)
    for candidate in query.get("thread_ts", []):
        if SLACK_TS.fullmatch(candidate):
            return candidate
    m = SLACK_LINK.search(value)
    return f"{m.group(1)}.{m.group(2)}" if m else ""


def gate() -> str:
    """Skip before any work when the summary could not be delivered. Returns
    the banner ts to reply under."""
    ts = thread_ts(os.environ.get("THREAD_TS", ""))
    if os.environ.get("DRY_RUN") == "true":
        return ts
    if os.environ.get("HAS_SLACK_TOKEN") != "true":
        skip("no Slack bot token, so the banner went out through the webhook and "
             "has no thread; pass slack-bot-token to post the summary")
    if not os.environ.get("CHANNEL_ID"):
        skip("no Slack channel id; pass the channel the banner was posted to")
    if not os.environ.get("THREAD_TS"):
        skip("the banner returned no message ts, so there is no thread to reply "
             "in; check that the bot token post succeeded in the notify job")
    if not ts:
        skip("thread-ts is neither a message ts nor a Slack message link; pass "
             "the banner's ts or its Copy link URL")
    return ts


def main() -> None:
    version = os.environ.get("VERSION", "").strip()
    repository = os.environ.get("REPOSITORY", "").strip()
    if not version or "/" not in repository:
        skip("VERSION and REPOSITORY (owner/name) are required")
    emit("thread_ts", gate())
    if is_shallow():
        skip("the checkout is shallow, so tags and the commit range are "
             "incomplete; check out the released repository with "
             "actions/checkout fetch-depth: 0 and fetch-tags: true")
    if not tag_exists(version):
        skip(f"tag {version} is not in the checkout; check out the released "
             "repository with fetch-depth: 0 and fetch-tags: true")

    prev = resolve_previous_tag(version, os.environ.get("PREVIOUS_TAG", "").strip())
    commits = list_commits(prev, version)
    if not commits:
        skip(f"no commits between {prev} and {version}")

    token = os.environ.get("GH_TOKEN", "")
    by_sha = fetch_prs(repository, [sha for sha, _ in commits], token)
    named = {sha: int(m.group(1)) for sha, subject in commits
             if by_sha.get(sha) is None and (m := SUBJECT_PR.search(subject))}
    if named:
        by_number = fetch_by_number(repository, sorted(set(named.values())), token)
        for sha, number in named.items():
            by_sha[sha] = by_number.get(number)
    prs: list[dict] = []
    seen: set[int] = set()
    bare: list[dict] = []
    for sha, subject in commits:
        pr = by_sha.get(sha)
        if pr is None:
            bare.append({"sha": sha[:10], "subject": subject})
        elif pr["number"] not in seen:
            seen.add(pr["number"])
            prs.append(pr_record(pr))

    doc = fit_budget({
        "repository": repository,
        "previous_tag": prev,
        "version": version,
        "diffstat": git("diff", "--shortstat", prev, version),
        "pull_requests": prs,
        "commits_without_pr": bare,
    })

    out_dir = Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir())
    input_file = out_dir / "release-summary-input.json"
    prs_file = out_dir / "release-summary-prs.json"
    input_file.write_text(json.dumps(doc, indent=1, ensure_ascii=False))
    prs_file.write_text(json.dumps({
        "repository": repository,
        "version": version,
        "previous_tag": prev,
        "server_url": os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
        "pull_requests": [{k: p[k] for k in ("number", "url", "title", "linear")}
                          for p in prs],
    }, ensure_ascii=False))

    print(f"release-summary: {len(prs)} PRs and {len(bare)} commits without a PR "
          f"between {prev} and {version}")
    emit("previous_tag", prev)
    emit("input_file", str(input_file))
    emit("prs_file", str(prs_file))
    emit("pr_count", str(len(prs)))
    if not prs:
        # commits_without_pr never reaches the summary, so the model would
        # have nothing to cite and render would end the run failed.
        skip(f"no merged pull requests between {prev} and {version}")
    if os.environ.get("HAS_ANTHROPIC_KEY") != "true":
        skip("no Anthropic API key; pass anthropic-api-key to generate the summary")
    emit("proceed", "true")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # never fail the release over a summary
        print(f"::warning::release-summary: collecting changes failed: {e}")
        emit("proceed", "false")
        emit("reason", f"collecting changes failed: {e}".replace("\n", " "))
        sys.exit(0)

"""Reject unsupported runners and malformed WIF configuration before authentication."""
import os
import re
import sys


def validate(env):
    if env.get("RUNNER_OS") != "Linux" or env.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise ValueError("a GitHub-hosted Linux runner is required")
    if env.get("GITHUB_EVENT_NAME") in ("pull_request", "pull_request_target") or env.get("GITHUB_REF", "").startswith("refs/pull/"):
        raise ValueError("pull request events and refs are not supported")
    if not env.get("GITHUB_EVENT_NAME") or not env.get("GITHUB_REF"):
        raise ValueError("GitHub event and ref are required")
    client_id = env.get("INPUT_CLIENT_ID", "")
    audience = env.get("INPUT_AUDIENCE", "")
    tailnet = env.get("INPUT_EXPECTED_TAILNET", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", client_id):
        raise ValueError("client-id is missing or invalid")
    if audience != f"api.tailscale.com/{client_id}":
        raise ValueError("audience must be the generated audience for client-id")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+", tailnet):
        raise ValueError("expected-tailnet must be a DNS suffix")


if __name__ == "__main__":
    try:
        validate(os.environ)
    except ValueError as exc:
        print(f"Preflight failed: {exc}", file=sys.stderr)
        sys.exit(1)

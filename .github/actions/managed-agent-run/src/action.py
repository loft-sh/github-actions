#!/usr/bin/env python3
import json
import os
import sys
import urllib.parse
import urllib.request


API_URL = os.getenv("ANTHROPIC_API_URL", "https://api.anthropic.com").rstrip("/")
BETA = "managed-agents-2026-04-01"


def append_step_summary(content):
    path = os.getenv("GITHUB_STEP_SUMMARY", "")
    if path:
        try:
            with open(path, "a", encoding="utf-8") as summary:
                summary.write(f"{content.rstrip()}\n\n")
        except OSError as error:
            print(f"::warning::managed-agent-run: could not write the step summary: {error}")


def warn(message):
    print(f"::warning::managed-agent-run: {message}")
    append_step_summary(f"> [!WARNING]\n> Managed agent run: {message}")


def set_output(name, value):
    path = os.getenv("GITHUB_OUTPUT", "")
    if path:
        with open(path, "a", encoding="utf-8") as output:
            output.write(f"{name}={value}\n")


def resolve_bool(name, raw_value, default, safe_default):
    value = raw_value.strip().lower()
    if not value:
        return default
    if value in ("true", "yes", "1", "on"):
        return True
    if value in ("false", "no", "0", "off"):
        return False
    warn(f"unrecognised {name}='{raw_value}'; using the safe default '{str(safe_default).lower()}'")
    return safe_default


def request(api_key, method, path, query=None):
    params = {"beta": "true", **(query or {})}
    url = f"{API_URL}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(
        url,
        data=b"" if method == "POST" else None,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "anthropic-beta": BETA,
            "content-type": "application/json",
        },
        method=method,
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def find_deployment(api_key, name):
    matches = []
    page = None
    while True:
        query = {"limit": "100", **({"page": page} if page else {})}
        payload = request(api_key, "GET", "/v1/deployments", query)
        matches.extend(d for d in payload.get("data", []) if d.get("name") == name)
        page = payload.get("next_page")
        if not page:
            return matches


def run():
    api_key = os.getenv("INPUT_ANTHROPIC_API_KEY", "").strip()
    name = os.getenv("INPUT_DEPLOYMENT_NAME", "").strip()
    # Unrecognised values fail safe: never start a run, and never a non-dry run.
    enabled = resolve_bool("enabled", os.getenv("INPUT_ENABLED", "true"), True, False)
    dry_run = resolve_bool("dry-run", os.getenv("INPUT_DRY_RUN", "false"), False, True)

    if not enabled:
        warn("disabled; skipping the managed agent run")
        return
    if not name:
        warn("deployment-name is empty; skipping")
        return
    if not api_key:
        warn("anthropic-api-key is empty; skipping")
        return

    matches = find_deployment(api_key, name)
    if len(matches) != 1:
        raise ValueError(f"expected exactly one deployment named '{name}', found {len(matches)}")
    deployment_id = matches[0]["id"]
    if dry_run:
        print(f"managed-agent-run: dry run: would run {name} ({deployment_id})")
        append_step_summary(f"Managed agent run: dry run, would run `{name}` (`{deployment_id}`).")
        return

    result = request(api_key, "POST", f"/v1/deployments/{urllib.parse.quote(deployment_id)}/run")
    session_id = result.get("session_id") or ""
    if not session_id:
        error = (result.get("error") or {}).get("type", "unknown")
        raise RuntimeError(f"run of {name} created no session (error: {error})")
    set_output("run-id", result.get("id", ""))
    set_output("session-id", session_id)
    print(f"managed-agent-run: started {name} ({deployment_id}): session {session_id}")
    append_step_summary(f"Managed agent run: started `{name}`, session `{session_id}`.")


def main():
    try:
        run()
    except Exception as error:
        warn(f"{error}; the calling job is unaffected")
    return 0


if __name__ == "__main__":
    sys.exit(main())

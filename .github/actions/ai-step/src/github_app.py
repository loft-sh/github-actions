# SPDX-License-Identifier: Apache-2.0
"""Renew a repository-scoped GitHub App token in a CMA MCP vault.

The signing and exchange follow ai-agents/scheduled-routines/src/github_app.py.
Only the trusted launcher sees the private key. Errors never include API bodies.
"""
import base64
import itertools
import json
import re
import subprocess
import tempfile
import time
import urllib.request
from datetime import datetime
from pathlib import Path

URL = "https://api.githubcopilot.com/mcp/"
PERMISSIONS = {"contents": "write", "pull_requests": "write", "metadata": "read"}


class AppError(Exception):
    pass


def _b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def mint(app_id, installation_id, key, repository):
    """Return the token and expiration after validating the returned scope."""
    owner, repo = repository.split("/", 1)
    now = int(time.time())
    header = _b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = _b64(json.dumps({"iat": now - 60, "exp": now + 540, "iss": app_id}).encode())
    signing_input = f"{header}.{payload}".encode()
    with tempfile.TemporaryDirectory(prefix="ai-step-app-") as directory:
        path = Path(directory) / "key.pem"
        path.touch(mode=0o600)
        path.write_bytes(key.encode())
        signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(path)],
                                   input=signing_input, capture_output=True, check=True,
                                   timeout=30).stdout
    jwt = f"{header}.{payload}.{_b64(signature)}"
    request = urllib.request.Request(
        f"https://api.github.com/app/installations/{installation_id}/access_tokens",
        data=json.dumps({"repositories": [repo], "permissions": PERMISSIONS}).encode(),
        headers={"Authorization": f"Bearer {jwt}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"}, method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    repos = data.get("repositories", [])
    if (len(repos) != 1 or repos[0].get("full_name", "").lower() != f"{owner}/{repo}".lower()
            or data.get("permissions") != PERMISSIONS):
        raise AppError("GitHub App token scope did not match the requested repository and permissions")
    expires = datetime.fromisoformat(data["expires_at"].replace("Z", "+00:00"))
    if expires.tzinfo is None or not data.get("token"):
        raise AppError("GitHub App token response was incomplete")
    return data["token"], expires.timestamp()


class GitHubCredential:
    def __init__(self, client, vault_id, app_id, installation_id, key, repository):
        if (not vault_id or not app_id.isdigit() or not installation_id.isdigit()
                or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
                or "PRIVATE KEY-----" not in key):
            raise AppError("invalid GitHub App configuration")
        self.client, self.vault_id = client, vault_id
        self.app_id, self.installation_id = app_id, installation_id
        self.key, self.repository = key, repository
        self.renew_at = 0

    def renew(self, force=False):
        if not force and time.time() < self.renew_at:
            return
        try:
            token, expiry = mint(self.app_id, self.installation_id, self.key, self.repository)
            now = time.time()
            if expiry - now <= 300:
                raise AppError("GitHub App token lifetime is too short")
            api = self.client.with_options(timeout=30, max_retries=0).beta.vaults.credentials
            matches = []
            credentials = list(itertools.islice(api.list(self.vault_id, limit=100), 101))
            if len(credentials) > 100:
                raise AppError("too many vault credentials to verify safely")
            for credential in credentials:
                auth = getattr(credential, "auth", None)
                url = getattr(auth, "mcp_server_url", None)
                named = getattr(credential, "display_name", None) == "github-pr-writer"
                if named and url is not None and url.rstrip("/") != URL.rstrip("/"):
                    raise AppError("GitHub credential URL differs")
                if (url is not None and url.rstrip("/") == URL.rstrip("/")) or (named and url is None):
                    # The QA deploy uses this same name when the write-only URL is absent.
                    matches.append(credential)
            if len(matches) > 1:
                raise AppError("multiple GitHub MCP credentials in vault")
            if not matches:
                raise AppError("GitHub MCP credential is missing from vault")
            if expiry - time.time() <= 300:
                raise AppError("GitHub App token lifetime is too short")
            auth = {"type": "static_bearer", "token": token}
            if getattr(matches[0].auth, "type", None) != "static_bearer":
                raise AppError("GitHub MCP credential has the wrong auth type")
            api.update(matches[0].id, vault_id=self.vault_id, auth=auth)
            self.renew_at = min(now + 45 * 60, expiry - 300)
        except AppError:
            raise
        except Exception:
            raise AppError("GitHub App token mint or vault update failed") from None

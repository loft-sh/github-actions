# SPDX-License-Identifier: Apache-2.0
"""Refresh the GitHub MCP bearer without creating an agent session."""
import os
import sys


def main():
    try:
        from anthropic import Anthropic
        from github_app import GitHubCredential

        client = Anthropic(default_headers={"anthropic-beta": "managed-agents-2026-04-01"})
        credential = GitHubCredential(
            client, os.environ.get("INPUT_VAULT_ID", ""),
            os.environ.get("INPUT_GITHUB_APP_ID", ""),
            os.environ.get("INPUT_GITHUB_APP_INSTALLATION_ID", ""),
            os.environ.get("INPUT_GITHUB_APP_PRIVATE_KEY", ""),
            os.environ.get("INPUT_GITHUB_APP_REPOSITORY", ""),
        )
        credential.renew(force=True)
    except Exception:
        # SDK and API errors can contain credentials. Never print their details.
        print("::error::GitHub MCP credential refresh failed", file=sys.stderr)
        return 1
    print("GitHub MCP credential refreshed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""backport-fix-imports: turn what the fix did into the backport PR comment.

Reads the notes fix.py left in RUNNER_TEMP and writes body, pr-number and
author to GITHUB_OUTPUT for sticky-pr-comment. Writes nothing when there is
nothing to tell the assignee. Never fails the job.

Env:
  BACKPORT_BRANCH, GH_TOKEN   as for fix.py
  RUNNER_TEMP                 where the notes are
"""
from __future__ import annotations

import json
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fix  # noqa: E402


def body(notes: dict) -> str:
    script = notes.get("script", {})
    lines = []
    if script.get("commit"):
        lines.append(f"- Module paths: fixed in {script['commit'][:10]} ({script.get('rewritten', 0)} file(s) "
                     f"rewritten, {script.get('hunks', 0)} import conflict(s) resolved).")
    left = script.get("left", {})
    if left:
        lines.append("- Left for you:")
        lines.extend(f"  - `{p}`: {r}" for p, r in sorted(left.items()))
    return "\n".join(["### Backport fix-imports", *lines]) if lines else ""


def main() -> int:
    try:
        path = Path(os.environ.get("RUNNER_TEMP", ".")) / fix.NOTES_FILE
        text = body(json.loads(path.read_text())) if path.is_file() else ""
        if not text:
            return 0
        pr = fix.backport_pr(os.environ["BACKPORT_BRANCH"])
        if pr is None:
            print("::warning::no open backport PR to comment on")
            return 0
        delim = f"EOF_{secrets.token_hex(8)}"
        with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as f:
            f.write(f"body<<{delim}\n{text}\n{delim}\n")
        fix.emit("pr-number", str(pr))
        # sticky-pr-comment only updates comments by this author.
        fix.emit("author", fix.github("GET", "/user")["login"])
    except Exception as e:  # noqa: BLE001 -- advisory: never fail the backport
        print(f"::warning::backport PR comment skipped: {str(e).splitlines()[0] if str(e) else type(e).__name__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

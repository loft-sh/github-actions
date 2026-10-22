#!/usr/bin/env python3
"""backport-fix-imports AI pass: resolve the Go conflict hunks fix.py left,
and commit an answer only when the package it lands in passes go vet.

Runs after fix.py in the same checkout, on the backport branch it left.

  prepare  write the conflicted .go files the backport changed, whole, to an
           input file for ai-step; sets input-file in GITHUB_OUTPUT, or
           nothing when there is no work or too much of it
  apply    splice the model's answers in, then gofmt and go vet each touched
           package; commit and push the packages that pass, revert the rest

A file is only changed when every hunk in it has an answer, and a package is
only committed when it compiles and vets, so a wrong or partial answer never
reaches the branch. Like fix.py this never fails the job: every path exits 0.

Env:
  TARGET_BRANCH, BACKPORT_BRANCH, REMOTE, PUSH, GH_TOKEN   as for fix.py
  RUNNER_TEMP   prepare: where the input file goes
  INPUT_FILE    apply: the file prepare wrote
  AI_RESULT     apply: the ai-step result JSON
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fix  # noqa: E402

MAX_HUNKS = 20
MAX_INPUT_BYTES = 300_000
VET_TIMEOUT = 900
MARKS = (fix.MARK_OURS, fix.MARK_BASE, fix.MARK_THEIRS)


def spans(lines: list[str]) -> list[tuple[int, int]]:
    """(first, last) line index of each complete conflict block."""
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith(fix.MARK_OURS):
            sep = next((j for j in range(i + 1, len(lines)) if lines[j] == fix.MARK_SEP), None)
            end = next((j for j in range(sep + 1, len(lines)) if lines[j].startswith(fix.MARK_THEIRS)), None) if sep else None
            if end is None:
                break
            out.append((i, end))
            i = end + 1
        else:
            i += 1
    return out


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def prepare() -> None:
    remote = os.environ.get("REMOTE") or "origin"
    target = os.environ["TARGET_BRANCH"]
    base = fix.git("merge-base", f"{remote}/{target}", "HEAD").strip()
    files = []
    for _, path in fix.changed_files(base):
        if not path.endswith(".go") or not Path(path).is_file():
            continue
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        hunks = spans(text.split("\n"))
        if hunks:
            files.append({"file": path, "sha256": digest(text), "hunks": len(hunks),
                          "ids": [f"{path}#{n}" for n in range(len(hunks))], "content": text})
    if not files:
        print("no Go conflicts left; the AI pass has nothing to do")
        return
    total = sum(f["hunks"] for f in files)
    module = fix.GOMOD_MODULE.search(Path("go.mod").read_text(encoding="utf-8")) if Path("go.mod").is_file() else None
    payload = json.dumps({"release_branch": target, "release_module": module.group(1) if module else "",
                          "files": files}, indent=1)
    if total > MAX_HUNKS or len(payload) > MAX_INPUT_BYTES:
        print(f"::notice::{total} Go conflict(s) in {len(files)} file(s) is too much for the AI pass; left for review")
        return
    out = Path(os.environ.get("RUNNER_TEMP", ".")) / "backport-ai-input.json"
    out.write_text(payload, encoding="utf-8")
    fix.emit("input-file", str(out))
    print(f"sending {total} Go conflict(s) in {len(files)} file(s) to the AI pass")


def resolve_file(text: str, answers: dict[str, dict], path: str) -> str | None:
    """The file with every hunk replaced, or None unless every hunk has a usable answer."""
    lines = text.split("\n")
    blocks = spans(lines)
    for n, (first, last) in reversed(list(enumerate(blocks))):
        answer = answers.get(f"{path}#{n}")
        if not answer or answer.get("resolvable") is not True or not isinstance(answer.get("code"), str):
            return None
        if any(l.startswith(MARKS) or l == fix.MARK_SEP for l in answer["code"].split("\n")):
            return None
        lines[first:last + 1] = answer["code"].split("\n")
    return "\n".join(lines)


def vet(package: str) -> tuple[bool, str]:
    try:
        res = subprocess.run(["go", "vet", package], capture_output=True, text=True, timeout=VET_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    lines = [l for l in (res.stdout + res.stderr).splitlines() if l and not l.startswith("#")]
    return res.returncode == 0, lines[0] if lines else ""


def apply() -> None:
    payload = json.loads(Path(os.environ["INPUT_FILE"]).read_text(encoding="utf-8"))
    result = json.loads(os.environ.get("AI_RESULT") or "{}")
    answers = {r["id"]: r for r in result.get("resolutions", []) if isinstance(r, dict) and "id" in r}

    written: dict[str, str] = {}
    for f in payload["files"]:
        path = f["file"]
        current = Path(path).read_text(encoding="utf-8", errors="replace")
        if digest(current) != f["sha256"]:
            print(f"::warning::{path} changed since it was sent to the AI pass; left for review")
            continue
        resolved = resolve_file(current, answers, path)
        if resolved is None:
            reasons = "; ".join(answers.get(i, {}).get("reason", "no answer") for i in f["ids"])
            print(f"::warning::{path}: not every conflict was resolved ({reasons}); left for review")
            continue
        Path(path).write_text(resolved, encoding="utf-8")
        written[path] = current

    by_package: dict[str, list[str]] = {}
    for path in written:
        by_package.setdefault(str(Path(path).parent), []).append(path)

    keep = []
    for directory, paths in sorted(by_package.items()):
        ok, why = True, ""
        others = [p for p in Path(directory).glob("*.go") if str(p) not in paths]
        if any(fix.has_markers(p.read_text(encoding="utf-8", errors="replace")) for p in others):
            ok, why = False, "another file in the package still has conflicts"
        if ok:
            res = subprocess.run(["gofmt", "-w", *paths], capture_output=True, text=True)
            ok, why = res.returncode == 0, res.stderr.strip().splitlines()[0] if res.returncode else ""
        if ok:
            ok, why = vet(f"./{directory}")
        if ok:
            keep.extend(paths)
            print(f"AI resolution for ./{directory} passes go vet")
        else:
            for p in paths:
                Path(p).write_text(written[p], encoding="utf-8")
            print(f"::warning::AI resolution for ./{directory} rejected ({why}); left for review")

    if not keep:
        return
    fix.git("add", "--", *keep)
    fix.git("-c", f"user.name={fix.BOT_NAME}", "-c", f"user.email={fix.BOT_EMAIL}", "commit", "-q",
            "-m", "fix(backport): resolve conflicts with ai", "-m",
            "Resolved by the backport AI pass and checked with go vet:\n" + "\n".join(f"- {p}" for p in keep))
    if os.environ.get("PUSH", "true") != "false":
        fix.git("push", "-q", os.environ.get("REMOTE") or "origin", f"HEAD:refs/heads/{os.environ['BACKPORT_BRANCH']}")
    print(f"committed AI resolutions for {len(keep)} file(s)")


def main() -> int:
    try:
        {"prepare": prepare, "apply": apply}[sys.argv[1]]()
    except Exception as e:  # noqa: BLE001 -- advisory: never fail the backport
        print(f"::warning::backport AI pass failed: {str(e).splitlines()[0] if str(e) else type(e).__name__}; "
              "conflicts are left for review")
    return 0


if __name__ == "__main__":
    sys.exit(main())

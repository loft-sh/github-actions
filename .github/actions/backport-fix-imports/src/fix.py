#!/usr/bin/env python3
"""backport-fix-imports: repair Go module paths on a backport branch whose
target release line is on an older module major than its source.

A cherry-pick from a v5 main onto a v4 release branch carries v5 import
paths with it, and conflicts wherever both sides edited an import block.
This script, run inside a full-history checkout of the repository:

  1. derives the path mapping from go.mod on both branches (only modules the
     repository owns: the module line and replaces that point into the repo)
  2. moves files the backport added under a source-only staging directory
     into the target's directory
  3. resolves conflict hunks that contain nothing but import lines
  4. rewrites the mapped import paths in the .go files the backport changed
  5. formats the files it resolved, commits as one commit and pushes

Conflicts in real code are left as they are and counted, for a person or a
later AI pass. A second run finds nothing to do, so re-runs are no-ops.

The action is advisory: every path, including an unexpected exception, ends
with exit 0 and a conclusion of fixed, unchanged, skipped or failed.

Env:
  TARGET_BRANCH    release branch the backport PR targets (required)
  SOURCE_BRANCH    branch the original change merged into (default main)
  BACKPORT_BRANCH  head branch of the backport PR (required)
  REMOTE           git remote to fetch from and push to (default origin)
  PUSH             "false" commits locally without pushing (default true)
  GH_TOKEN         token used for fetch and push; never logged
  GITHUB_OUTPUT    standard Actions output file
"""
from __future__ import annotations

import base64
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

MARK_OURS = "<<<<<<< "
MARK_BASE = "||||||| "
MARK_SEP = "======="
MARK_THEIRS = ">>>>>>> "

GOMOD_MODULE = re.compile(r"^module\s+(\S+)", re.M)
# Single-line replaces and the lines of a replace ( ... ) block; only a local
# right-hand side ("./" or "../") names a module this repository owns.
GOMOD_REPLACE = re.compile(r"^[ \t]*(?:replace[ \t]+)?(\S+)(?:[ \t]+\S+)?[ \t]+=>[ \t]+(\.\.?/\S+)[ \t]*$", re.M)
MAJOR_SUFFIX = re.compile(r"/v\d+$")

# One import spec per line: optional name, quoted path, optional comment.
IMPORT_SPEC = re.compile(r'^\s*(?:([A-Za-z_][A-Za-z0-9_]*|\.)\s+)?"([^"\s]+)"\s*(?://.*)?$')
COMMENT = re.compile(r"^\s*//")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

BOT_NAME = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"


class Skip(Exception):
    """An expected condition: nothing to fix here."""


def emit(key: str, value: str) -> None:
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as f:
        f.write(f"{key}={value}\n")


def git(*args: str, check: bool = True) -> str:
    env = os.environ.copy()
    token = os.environ.get("GH_TOKEN", "")
    if token:
        # The PAT goes in through the environment, never argv or .git/config.
        auth = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.extraheader",
                   GIT_CONFIG_VALUE_0=f"AUTHORIZATION: basic {auth}")
    res = subprocess.run(["git", *args], capture_output=True, text=True, env=env)
    if check and res.returncode != 0:
        raise RuntimeError(f"git {args[0]} failed: {res.stderr.strip()}")
    return res.stdout


def strip_major(path: str) -> str:
    return MAJOR_SUFFIX.sub("", path)


def owned_modules(gomod: str) -> dict[str, tuple[str, str]]:
    """Map each owned module, keyed by its path without the major suffix, to
    (full path, local directory or "")."""
    owned: dict[str, tuple[str, str]] = {}
    m = GOMOD_MODULE.search(gomod)
    if m:
        owned[strip_major(m.group(1))] = (m.group(1), "")
    for path, local in GOMOD_REPLACE.findall(gomod):
        owned[strip_major(path)] = (path, local.removeprefix("./").rstrip("/"))
    return owned


def module_mapping(source_gomod: str, target_gomod: str) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """Return (import path pairs, directory pairs) that differ between source and target."""
    source, target = owned_modules(source_gomod), owned_modules(target_gomod)
    paths, dirs = [], []
    for base, (src_path, src_dir) in source.items():
        if base not in target:
            continue
        tgt_path, tgt_dir = target[base]
        if src_path != tgt_path:
            paths.append((src_path, tgt_path))
        if src_dir and tgt_dir and src_dir != tgt_dir:
            dirs.append((src_dir, tgt_dir))
    # Longest first, so a nested module is rewritten before its parent.
    paths.sort(key=lambda p: len(p[0]), reverse=True)
    return paths, dirs


def rewrite_paths(text: str, paths: list[tuple[str, str]]) -> str:
    # Only at the start of a string literal and on a path boundary, so
    # loft/v5 never matches loft/v50 or a mention in prose.
    for src, tgt in paths:
        text = re.sub(r'(?<=")' + re.escape(src) + r'(?=["/])', tgt, text)
    return text


def import_name(line: str) -> str | None:
    """Package name an import line binds, or None when it cannot be told
    (blank and dot imports, paths whose name is not their last element)."""
    m = IMPORT_SPEC.match(line)
    if not m or m.group(1) in (".", "_"):
        return None
    if m.group(1):
        return m.group(1)
    parts = m.group(2).split("/")
    last = parts[-1]
    if re.fullmatch(r"v\d+", last) and len(parts) > 1:
        last = parts[-2]
    last = re.sub(r"\.v\d+$", "", last)
    return last if IDENT.fullmatch(last) else None


def is_import_only(lines: list[str]) -> bool:
    return all(not l.strip() or COMMENT.match(l) or IMPORT_SPEC.match(l) for l in lines)


def in_import_block(lines: list[str], index: int) -> bool:
    for line in reversed(lines[:index]):
        stripped = line.strip()
        if stripped == "import (":
            return True
        if stripped == ")" or stripped.startswith(("func ", "type ", "var ", "const ")):
            return False
    return False


def block_end(lines: list[str], index: int) -> int:
    for i in range(index, len(lines)):
        if lines[i].strip() == ")":
            return i
    return len(lines)


def merge_imports(ours: list[str], theirs: list[str], body: str) -> list[str]:
    """Theirs (the backported change) wins. An import only the target side
    has stays while the file still uses it, and whenever its name cannot be
    told: an unused import fails the build as surely as a missing one."""
    merged = list(theirs)
    seen = {m.group(2) for m in map(IMPORT_SPEC.match, theirs) if m}
    for line in ours:
        m = IMPORT_SPEC.match(line)
        if not m or m.group(2) in seen:
            continue
        name = import_name(line)
        if name is None or re.search(r"\b" + re.escape(name) + r"\.", body):
            merged.append(line)
            seen.add(m.group(2))
    return [l for l in merged if l.strip()]


def resolve_import_hunks(text: str, paths: list[tuple[str, str]]) -> tuple[str, int]:
    """Resolve conflict hunks made only of import lines inside an import
    block. Returns the new text and how many hunks were resolved."""
    lines = text.split("\n")
    out: list[str] = []
    resolved = 0
    i = 0
    while i < len(lines):
        if not lines[i].startswith(MARK_OURS):
            out.append(lines[i])
            i += 1
            continue
        try:
            sep = next(j for j in range(i + 1, len(lines)) if lines[j] == MARK_SEP)
            end = next(j for j in range(sep + 1, len(lines)) if lines[j].startswith(MARK_THEIRS))
        except StopIteration:
            out.extend(lines[i:])
            break
        base = next((j for j in range(i + 1, sep) if lines[j].startswith(MARK_BASE)), sep)
        ours = [rewrite_paths(l, paths) for l in lines[i + 1:base]]
        theirs = [rewrite_paths(l, paths) for l in lines[sep + 1:end]]
        if is_import_only(ours) and is_import_only(theirs) and in_import_block(lines, i):
            body = "\n".join(lines[block_end(lines, end + 1) + 1:])
            out.extend(merge_imports(ours, theirs, body))
            resolved += 1
        else:
            out.extend(lines[i:end + 1])
        i = end + 1
    return "\n".join(out), resolved


def has_markers(text: str) -> bool:
    return any(l.startswith(MARK_OURS) for l in text.split("\n"))


def move_files(changed: list[str], dirs: list[tuple[str, str]]) -> list[str]:
    """Move files added under a source-only directory into the target's."""
    result = []
    for path in changed:
        new = path
        for src_dir, tgt_dir in dirs:
            if path.startswith(src_dir + "/"):
                candidate = tgt_dir + path[len(src_dir):]
                if Path(candidate).exists():
                    print(f"::warning::{path}: {candidate} already exists, left in place; move it by hand")
                else:
                    Path(candidate).parent.mkdir(parents=True, exist_ok=True)
                    git("mv", path, candidate)
                    print(f"moved {path} -> {candidate}")
                    new = candidate
                break
        result.append(new)
    return result


def gofmt(files: list[str]) -> None:
    if not files:
        return
    if not shutil.which("gofmt"):
        print("::warning::gofmt not on PATH; resolved import blocks are left unformatted")
        return
    res = subprocess.run(["gofmt", "-w", *files], capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"gofmt rejected the result, nothing committed: {res.stderr.strip()}")


def run() -> dict[str, str]:
    target = os.environ.get("TARGET_BRANCH", "")
    branch = os.environ.get("BACKPORT_BRANCH", "")
    source = os.environ.get("SOURCE_BRANCH") or "main"
    remote = os.environ.get("REMOTE") or "origin"
    push = os.environ.get("PUSH", "true") != "false"
    if not target or not branch:
        raise Skip("target-branch and backport-branch are required; pass both from the backport job")

    git("fetch", "-q", "--no-tags", remote,
        *(f"+refs/heads/{b}:refs/remotes/{remote}/{b}" for b in (target, source, branch)))
    gomods = []
    for b in (source, target):
        content = git("show", f"{remote}/{b}:go.mod", check=False)
        if not content:
            raise Skip(f"no go.mod at the root of {b}; nothing to map")
        gomods.append(content)
    paths, dirs = module_mapping(*gomods)
    if not paths and not dirs:
        raise Skip(f"{source} and {target} use the same module paths")

    git("checkout", "-q", "-B", branch, f"{remote}/{branch}")
    base = git("merge-base", f"{remote}/{target}", "HEAD").strip()
    changed = [p for p in git("diff", "--name-only", "--diff-filter=AMR", base, "HEAD").splitlines() if p]
    changed = move_files(changed, dirs)
    moved = git("diff", "--cached", "--name-only").strip() != ""

    rewritten, to_format, hunks = [], [], 0
    for path in changed:
        if not path.endswith(".go") or not Path(path).is_file():
            continue
        before = Path(path).read_text(encoding="utf-8")
        after, resolved = resolve_import_hunks(before, paths)
        after = rewrite_paths(after, paths)
        if after != before:
            Path(path).write_text(after, encoding="utf-8")
            rewritten.append(path)
            hunks += resolved
            if resolved and not has_markers(after):
                to_format.append(path)
    gofmt(to_format)

    remaining = [p for p in changed if Path(p).is_file() and has_markers(Path(p).read_text(encoding="utf-8", errors="replace"))]
    for p in remaining:
        print(f"::warning::{p}: conflict markers outside import blocks remain; resolve them by hand")
    result = {"files-changed": str(len(rewritten)), "hunks-resolved": str(hunks),
              "conflicts-remaining": str(len(remaining)), "commit": ""}

    if not rewritten and not moved:
        return {**result, "conclusion": "unchanged", "reason": "no module paths to rewrite"}

    if rewritten:
        git("add", "--", *rewritten)
    mapping = ", ".join(f"{s} -> {t}" for s, t in paths)
    git("-c", f"user.name={BOT_NAME}", "-c", f"user.email={BOT_EMAIL}", "commit", "-q",
        "-m", f"fix(backport): use {target} module paths", "-m", f"Rewrote {mapping}.")
    sha = git("rev-parse", "HEAD").strip()
    result["commit"] = sha
    if push:
        git("push", "-q", remote, f"HEAD:refs/heads/{branch}")
    reason = f"rewrote {len(rewritten)} file(s), resolved {hunks} import conflict(s)"
    return {**result, "conclusion": "fixed", "reason": reason}


def main() -> int:
    try:
        result = run()
    except Skip as e:
        result = {"conclusion": "skipped", "reason": str(e)}
        print(f"::notice::{e}")
    except Exception as e:  # noqa: BLE001 -- advisory: never fail the backport
        result = {"conclusion": "failed", "reason": str(e).splitlines()[0] if str(e) else type(e).__name__}
        print(f"::warning::backport-fix-imports failed: {result['reason']}; the backport PR is unchanged, fix it by hand")
    for key, value in result.items():
        emit(key, value)
    print(f"conclusion={result['conclusion']} reason={result['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

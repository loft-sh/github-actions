#!/usr/bin/env python3
"""release-notes: write the GitHub release body for an OSS subtree that a
monorepo publishes as its own repository.

Lists the first-parent commits between the previous tag and the release tag
that touch the subtree, picked by the same rev-list oss-commit-sync's export
runs. Commits outside the subtree are commercial and are left out.

Everything is computed from the monorepo checkout. The OSS release tag is a
parentless snapshot, so the OSS repository's own history cannot bound the
range (see the README).

Unlike release-summary this is not advisory: it runs before anything is
published, and a release body that is empty or wrong is a bug, so every
failure exits 1 with an ::error:: line.

Env:
  VERSION         release tag (required)
  PREVIOUS_TAG    optional override for the comparison base
  SUBTREE_PREFIX  path of the OSS subtree in the monorepo (required)
  REPOSITORY      monorepo owner/name, whose refs the body drops (required)
  OSS_REPOSITORY  OSS owner/name, for links to the OSS commits that imported
                  commits replay (required)
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "release-lib"))
import release_tags  # noqa: E402
from release_tags import is_shallow, tag_exists  # noqa: E402

# The filters of the monorepo's goreleaser changelog: ^docs: and ^test:.
EXCLUDED = re.compile(r"(?:docs|test):")
OSS_TRAILER = "oss-commit"
SHA = re.compile(r"[0-9a-f]{7,40}")
# GitHub links GH-N like #N.
NUMBER_REF = r"(?:#|GH-)\d+"
# A ref with no repository in front; owner/repo#N names its repository.
BARE_REF = re.compile(r"(?<![A-Za-z0-9])(?:#|GH-)(\d+)", re.I)
# A URL path, which may hold balanced parentheses, as in a(b).go.
URL_TAIL = r"(?:[^\s()<>]|\([^\s()]*\))*"
# Every pattern below runs on subjects replayed verbatim from OSS before the
# release is published, so each matches in one pass: no two adjacent
# repeats that can split the same run of text between them.
# A parenthesised group, which may hold one level of parentheses, as a URL
# ending in a(b).go does.
PAREN = re.compile(r"[ \t]?\(((?:[^()]|\([^()]*\))*)\)")
SEPARATORS = re.compile(r"(?:[\s,&]|\band\b)+", re.I)
SPACES = re.compile(r"[ \t]{2,}")
BACKTICKS = re.compile(r"`+")
# GitHub stops matching a code span fence of about 80 backticks.
LONG_BACKTICKS = re.compile(r"`{4,}")
# CommonMark ends a line at a bare CR, and the other control characters and
# separators have no place in a one-line entry; any of them would let the
# rest of a replayed subject render as markdown. Bidi controls go too: an
# unclosed override flows past the subject and shows the commit link after
# it reversed.
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f  ؜‎‏‪-‮⁦-⁩]+")
# GitHub caps a PR title at 256 characters, so a squash subject with its
# " (#N)" fits, and every pattern here stays cheap on a replayed subject of
# any length.
MAX_SUBJECT = 300
# GitHub limits a release body to 125,000 characters.
MAX_BODY_BYTES = 125_000


class NotesError(Exception):
    """The notes cannot be written. The message names the remedy."""


def fail(reason: str) -> None:
    print(f"::error::release-notes: {reason}".replace("\n", " "))
    sys.exit(1)


def emit(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as f:
            f.write(f"{key}={value}\n")


def oss_commits(message: str, block: str) -> list[str]:
    """The Oss-Commit values oss-commit-sync's trailer_scan reads: message
    lines with the key in any case, optional blanks around the colon, a 7 to
    40 digit hex value and no non-blank indented line folding it, then the
    values in git's own trailer block, already unfolded by git."""
    found: list[str] = []
    pending = ""
    for line in message.split("\n"):
        if line[:1] in (" ", "\t") and line.strip(" \t\r"):
            pending = ""
            continue
        if SHA.fullmatch(pending) and pending not in found:
            found.append(pending)
        pending = ""
        low = line.rstrip(" \t\r").lower()
        if not low.startswith(OSS_TRAILER):
            continue
        rest = low[len(OSS_TRAILER):].lstrip(" \t")
        if rest.startswith(":"):
            pending = rest[1:].lstrip(" \t")
    if SHA.fullmatch(pending) and pending not in found:
        found.append(pending)
    for line in block.split("\n"):
        value = line.lower().rstrip(" \t\r")
        if SHA.fullmatch(value) and value not in found:
            found.append(value)
    return found


def list_commits(prev: str, version: str, path: str) -> list[dict]:
    """The commits oss-commit-sync's export replays, picked by the same
    rev-list: first-parent commits in prev..version that touch path. Oldest
    first, with their subject and the OSS commits each one was imported
    from."""
    # NUL frames every field and record: it is the one byte a commit message
    # cannot hold, and import.sh replays OSS messages into the monorepo
    # verbatim. Bytes are decoded here, not by the locale, so a message that
    # is not UTF-8 cannot stop the release.
    out = subprocess.run(
        ["git", "log", "-z", "--first-parent", "--reverse",
         "--format=%H%x00%s%x00%B%x00%(trailers:key=Oss-Commit,valueonly,unfold)",
         f"{prev}..{version}", "--", path],
        check=True, capture_output=True).stdout.decode("utf-8", "replace")
    fields = out.split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    if len(fields) % 4:
        raise NotesError(f"git log printed {len(fields)} fields, not a whole "
                         "number of commits")
    return [{"sha": fields[i], "subject": capped(fields[i + 1]) or "(no message)",
             "oss_commits": oss_commits(fields[i + 2], fields[i + 3])}
            for i in range(0, len(fields), 4)]


def subtree_path(version: str, prefix: str) -> str:
    """prefix as a path below the root that is a directory at version."""
    path = os.path.normpath(prefix.strip())
    if os.path.isabs(path) or path == "." or path.startswith(".."):
        raise NotesError(f"subtree-prefix '{prefix}' names the repository root or a "
                         "path outside it; pass the subtree's path, such as "
                         "staging/github.com/loft-sh/vcluster")
    kind = subprocess.run(["git", "cat-file", "-t", f"{version}:{path}"],
                          capture_output=True, text=True)
    if kind.returncode != 0 or kind.stdout.strip() != "tree":
        raise NotesError(f"subtree-prefix '{prefix}' is not a directory at {version}; "
                         "pass the subtree's path, such as "
                         "staging/github.com/loft-sh/vcluster")
    return path


def ref_patterns(repository: str = "") -> tuple[re.Pattern, re.Pattern | None]:
    """Any ref this body drops, and a lone ref into repository: a URL that
    names it, or owner/repo followed by #, @ or /. A bare owner/repo in
    prose links nowhere and stays. Without a repository only #N and GH-N
    refs drop."""
    if not repository:
        return re.compile(NUMBER_REF, re.I), None
    repo = re.escape(repository)
    url = (rf"<?(?:https?://|www\.)[^\s/<>]*(?:/repos)?/{repo}(?![\w-])"
           rf"(?:[./#@?]{URL_TAIL})?>?")
    short = rf"(?<![\w./-]){repo}[#@/]{URL_TAIL}"
    return (re.compile(rf"{url}|{short}|{NUMBER_REF}", re.I),
            re.compile(rf"[ \t]?(?:{url}|{short})", re.I))


def without_refs(subject: str, patterns: tuple) -> str:
    any_ref, lone = patterns

    def group(match: re.Match) -> str:
        """A parenthesised group goes when it holds nothing but refs."""
        tokens = [t for t in SEPARATORS.split(match.group(1)) if t]
        return "" if tokens and all(any_ref.fullmatch(t) for t in tokens) else match.group(0)

    subject = PAREN.sub(group, subject)
    if lone:
        subject = lone.sub("", subject)
    subject = BARE_REF.sub(r"\1", subject)
    return SPACES.sub(" ", subject).strip()


def code_span(text: str) -> str:
    """text as inline code, which GitHub renders as it is: no links,
    mentions, refs, commit shas, HTML, entities or markdown. The delimiter
    is longer than any backtick run inside, and the spaces CommonMark strips
    from both ends pad text that starts or ends with a backtick. Longer
    backtick runs shrink to three, so the fence stays one GitHub closes."""
    text = LONG_BACKTICKS.sub("```", text)
    fence = "`" * (max((len(run) for run in BACKTICKS.findall(text)), default=0) + 1)
    pad = " " if text.startswith("`") or text.endswith("`") else ""
    return f"{fence}{pad}{text}{pad}{fence}"


def capped(subject: str) -> str:
    """subject on one line, cut to MAX_SUBJECT characters."""
    subject = CONTROL.sub(" ", subject).strip()
    return subject if len(subject) <= MAX_SUBJECT else subject[:MAX_SUBJECT - 1] + "…"


def oss_source(commit: dict) -> str:
    """The OSS commit an imported commit replays. Empty for a commit made in
    the monorepo, and for a bulk sync that carries several OSS commits."""
    return commit["oss_commits"][0] if len(commit["oss_commits"]) == 1 else ""


def line(commit: dict, server: str, oss_repository: str, refs: tuple) -> str:
    """No refs into the monorepo: it is private, and its PR numbers link
    unrelated PRs on the OSS repository. A commit imported from OSS can
    carry its OSS PR ref too, and the subject cannot tell the two apart, so
    every ref goes and the OSS commit is linked instead, whose page names
    its PR. Stripping takes out the refs a reader would see; the code span
    keeps whatever is left from linking."""
    subject = code_span(without_refs(commit["subject"], refs) or "(no message)")
    if source := oss_source(commit):
        return f"* {subject} ([{source[:10]}]({server}/{oss_repository}/commit/{source}))"
    return f"* {subject}"


def render(lines: list[str], prev: str, omitted: int) -> str:
    parts = ["## Changelog", "", f"Changes since {prev}.", ""]
    parts += lines[omitted:] or ["No changes."]
    if omitted:
        parts += ["", f"{omitted} earlier changes are not listed."]
    return "\n".join(parts) + "\n"


def fits(body: str) -> bool:
    return len(body.encode()) <= MAX_BODY_BYTES


def build(version: str, override: str, prefix: str, repository: str,
          oss_repository: str) -> tuple[str, str, int]:
    """The previous tag, the body and how many changes it lists."""
    if is_shallow():
        raise NotesError("the checkout is shallow, so tags and the commit range "
                         "are incomplete; check out with fetch-depth: 0 and "
                         "fetch tags")
    if not tag_exists(version):
        raise NotesError(f"tag {version} is not in the checkout; check out with "
                         "fetch-depth: 0 and fetch tags")
    path = subtree_path(version, prefix)
    try:
        prev = release_tags.resolve_previous_tag(version, override)
    except release_tags.NoPreviousTag as e:
        raise NotesError(str(e)) from None

    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    refs = ref_patterns(repository)
    lines = [line(c, server, oss_repository, refs)
             for c in list_commits(prev, version, path)
             if not EXCLUDED.match(c["subject"])]

    omitted = 0
    body = render(lines, prev, 0)
    if not fits(body):
        # The oldest entries go first, so the newest changes stay listed.
        low, high = 1, len(lines)
        while low < high:
            mid = (low + high) // 2
            if fits(render(lines, prev, mid)):
                high = mid
            else:
                low = mid + 1
        omitted = low
        body = render(lines, prev, omitted)
        if not fits(body):
            raise NotesError(f"the release body exceeds {MAX_BODY_BYTES} bytes "
                             "with no entries listed")
        print(f"::warning::release-notes: {len(lines)} changes between {prev} "
              f"and {version}; the newest {len(lines) - omitted} fit a "
              f"{MAX_BODY_BYTES}-byte release body")
    return prev, body, len(lines) - omitted


def main() -> None:
    env = {k: os.environ.get(k, "").strip() for k in
           ("VERSION", "PREVIOUS_TAG", "SUBTREE_PREFIX", "REPOSITORY", "OSS_REPOSITORY")}
    missing = [k for k in ("VERSION", "SUBTREE_PREFIX") if not env[k]]
    missing += [k for k in ("REPOSITORY", "OSS_REPOSITORY") if "/" not in env[k]]
    if missing:
        fail(f"{', '.join(missing)} must be set (repositories as owner/name)")
    try:
        prev, body, count = build(
            env["VERSION"], env["PREVIOUS_TAG"], env["SUBTREE_PREFIX"],
            env["REPOSITORY"], env["OSS_REPOSITORY"])
        notes_file = Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()) / "release-notes.md"
        notes_file.write_text(body)
        emit("previous-tag", prev)
        emit("notes-file", str(notes_file))
        emit("count", str(count))
    except NotesError as e:
        fail(str(e))
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode("utf-8", "replace") if isinstance(e.stderr, bytes) else e.stderr
        fail(f"git {' '.join(e.cmd[1:])} failed: {(stderr or '').strip()}")
    except Exception as e:  # every failure names itself in an annotation
        fail(f"unexpected {type(e).__name__}: {e}")
    print(f"release-notes: {count} open source changes between {prev} and "
          f"{env['VERSION']}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""release-notes: write the GitHub release bodies for a monorepo release that
also publishes an OSS subtree as its own repository.

Lists the first-parent commits between the previous tag and the release tag,
and splits them into two sections: "Open source" holds every commit that
touches the subtree, picked by the same rev-list oss-commit-sync's export
runs, and "Commercial" holds the rest. Two files come out of one walk:

  release-notes.md         the monorepo release: PR refs and commit links kept
  release-notes-public.md  the OSS release: no refs into the private monorepo

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
  REPOSITORY      monorepo owner/name, for commit and compare links (required)
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
from release_tags import git, is_shallow, tag_exists  # noqa: E402

# The goreleaser changelog filters these notes replace: ^docs: and ^test:.
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
# GitHub reads @name after anything but an ASCII letter or digit as a
# mention, which notifies that account and lists it as a contributor; a word
# joiner after the @ stops that without changing how the subject looks.
MENTION = re.compile(r"(?<![A-Za-z0-9])@(?=[A-Za-z0-9])")
WORD_JOINER = "\u2060"
# GitHub decodes an entity such as &#x40; before it looks for mentions and
# refs, and inside HTML it decodes &#64 without its semicolon too. Other &
# is left alone: code spans and bare URLs show an escape literally, and
# without HTML GitHub decodes nothing that lacks its semicolon.
ENTITY = re.compile(r"&(?=#?[A-Za-z0-9]+;)")
HTML_ENTITY = re.compile(r"&(?=#|[A-Za-z0-9]+;)")
BACKTICKS = re.compile(r"`+")
# GitHub stops matching a code span fence of about 80 backticks.
LONG_BACKTICKS = re.compile(r"`{4,}")
# CommonMark ends a line at a bare CR, and the other control characters and
# separators have no place in a one-line entry; any of them would let the
# rest of a replayed subject render as markdown. Bidi controls go too: an
# unclosed override flows past the subject and shows the commit links after
# it reversed.
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]+")
# GitHub caps a PR title at 256 characters, so a squash subject with its
# " (#N)" fits, and every pattern here stays cheap on a replayed subject of
# any length.
MAX_SUBJECT = 300
# goreleaser cuts a longer body to this many bytes from the end, which would
# drop the newest entries and the footer.
MAX_BODY_BYTES = 125_000
OPEN_SOURCE = "Open source"
COMMERCIAL = "Commercial"


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


def list_commits(prev: str, version: str) -> list[dict]:
    """First-parent commits in prev..version, oldest first, with their subject
    and the OSS commits each one was imported from."""
    # NUL frames every field and record: it is the one byte a commit message
    # cannot hold, and import.sh replays OSS messages into the monorepo
    # verbatim. Bytes are decoded here, not by the locale, so a message that
    # is not UTF-8 cannot stop the release.
    out = subprocess.run(
        ["git", "log", "-z", "--first-parent", "--reverse",
         "--format=%H%x00%s%x00%B%x00%(trailers:key=Oss-Commit,valueonly,unfold)",
         f"{prev}..{version}"],
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


def subtree_commits(prev: str, version: str, path: str) -> set[str]:
    """The commits oss-commit-sync's export replays, picked by the same
    rev-list: first-parent commits that touch the subtree."""
    out = git("rev-list", "--first-parent", f"{prev}..{version}", "--", path)
    return set(out.split())


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


NUMBER_REFS = ref_patterns()


def without_refs(subject: str, patterns: tuple = NUMBER_REFS) -> str:
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


def no_mentions(subject: str) -> str:
    """For the monorepo body, which an entity such as &#x40; could otherwise
    reach too."""
    entity = HTML_ENTITY if "<" in subject else ENTITY
    return MENTION.sub("@" + WORD_JOINER, entity.sub("&amp;", subject))


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
    return subject if len(subject) <= MAX_SUBJECT else subject[:MAX_SUBJECT - 1] + "\u2026"


def commit_link(server: str, repository: str, sha: str, label: str = "") -> str:
    return f"[{label or sha[:10]}]({server}/{repository}/commit/{sha})"


def oss_source(commit: dict) -> str:
    """The OSS commit an imported commit replays. Empty for a commit made in
    the monorepo, and for a bulk sync that carries several OSS commits."""
    return commit["oss_commits"][0] if len(commit["oss_commits"]) == 1 else ""


def private_line(commit: dict, server: str, repository: str, oss_repository: str) -> str:
    """A commit imported from OSS can carry an OSS PR ref and the ref of the
    monorepo PR that merged the import, and the subject cannot tell which is
    which, so its refs are replaced by a link to the OSS commit."""
    links = [commit_link(server, repository, commit["sha"])]
    subject = commit["subject"]
    if commit["oss_commits"]:
        subject = without_refs(subject)
        if source := oss_source(commit):
            links.append(commit_link(server, oss_repository, source,
                                     f"{oss_repository}@{source[:10]}"))
    return f"* {no_mentions(subject)} ({', '.join(links)})"


def public_line(commit: dict, server: str, oss_repository: str,
                private: tuple) -> str:
    """No refs into the monorepo: it is private, and its PR numbers link
    unrelated PRs on the OSS repository. Stripping takes out the refs a
    reader would see; the code span keeps whatever is left from linking.
    A commit imported from OSS links the OSS commit instead, whose page
    names its PR."""
    subject = code_span(without_refs(commit["subject"], private) or "(no message)")
    if source := oss_source(commit):
        return f"* {subject} ({commit_link(server, oss_repository, source)})"
    return f"* {subject}"


def render(sections: dict[str, list[str]], prev: str, omitted: int, footer: str) -> str:
    parts = ["## Changelog", "", f"Changes since {prev}."]
    if not any(sections.values()):
        parts += ["", "No changes."]
    for title, lines in sections.items():
        if lines:
            parts += ["", f"### {title}", "", *lines]
    if omitted:
        parts += ["", f"{omitted} earlier changes are not listed."]
    if footer:
        parts += ["", footer]
    return "\n".join(parts) + "\n"


def bodies(entries: list[tuple[str, str, str]], omitted: int, prev: str,
           compare: str) -> tuple[str, str]:
    """Both bodies without the oldest omitted entries."""
    private = {OPEN_SOURCE: [], COMMERCIAL: []}
    public = {OPEN_SOURCE: [], COMMERCIAL: []}
    for section, private_text, public_text in entries[omitted:]:
        private[section].append(private_text)
        public[section].append(public_text)
    return (render(private, prev, omitted, compare),
            render(public, prev, omitted, ""))


def fits(texts: tuple[str, str]) -> bool:
    return all(len(t.encode()) <= MAX_BODY_BYTES for t in texts)


def build(version: str, override: str, prefix: str, repository: str,
          oss_repository: str) -> tuple[str, str, str, dict[str, int]]:
    """The previous tag, the private and public bodies, and section counts."""
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

    commits = [c for c in list_commits(prev, version)
               if not EXCLUDED.match(c["subject"])]
    in_subtree = subtree_commits(prev, version, path)
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    private_refs = ref_patterns(repository)
    entries = [(OPEN_SOURCE if c["sha"] in in_subtree else COMMERCIAL,
                private_line(c, server, repository, oss_repository),
                public_line(c, server, oss_repository, private_refs))
               for c in commits]

    # Only the monorepo release gets a compare link: the OSS release tags are
    # parentless snapshots, so a compare between two of them shows nothing.
    compare = f"**Full Changelog**: {server}/{repository}/compare/{prev}...{version}"
    omitted = 0
    texts = bodies(entries, 0, prev, compare)
    if not fits(texts):
        # Both bodies drop the same oldest entries, so they list the same
        # changes; the monorepo body is the longer one and decides how many.
        low, high = 1, len(entries)
        while low < high:
            mid = (low + high) // 2
            if fits(bodies(entries, mid, prev, compare)):
                high = mid
            else:
                low = mid + 1
        omitted = low
        texts = bodies(entries, omitted, prev, compare)
        if not fits(texts):
            raise NotesError(f"the release body exceeds {MAX_BODY_BYTES} bytes "
                             "with no entries listed")
        print(f"::warning::release-notes: {len(entries)} changes between {prev} "
              f"and {version}; the newest {len(entries) - omitted} fit a "
              f"{MAX_BODY_BYTES}-byte release body")
    kept = entries[omitted:]
    counts = {"open-source": sum(e[0] == OPEN_SOURCE for e in kept),
              "commercial": sum(e[0] == COMMERCIAL for e in kept)}
    return prev, texts[0], texts[1], counts


def main() -> None:
    env = {k: os.environ.get(k, "").strip() for k in
           ("VERSION", "PREVIOUS_TAG", "SUBTREE_PREFIX", "REPOSITORY", "OSS_REPOSITORY")}
    missing = [k for k in ("VERSION", "SUBTREE_PREFIX") if not env[k]]
    missing += [k for k in ("REPOSITORY", "OSS_REPOSITORY") if "/" not in env[k]]
    if missing:
        fail(f"{', '.join(missing)} must be set (repositories as owner/name)")
    try:
        prev, private, public, counts = build(
            env["VERSION"], env["PREVIOUS_TAG"], env["SUBTREE_PREFIX"],
            env["REPOSITORY"], env["OSS_REPOSITORY"])
        out_dir = Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir())
        notes_file = out_dir / "release-notes.md"
        public_file = out_dir / "release-notes-public.md"
        notes_file.write_text(private)
        public_file.write_text(public)
        emit("previous-tag", prev)
        emit("notes-file", str(notes_file))
        emit("public-notes-file", str(public_file))
        emit("open-source-count", str(counts["open-source"]))
        emit("commercial-count", str(counts["commercial"]))
    except NotesError as e:
        fail(str(e))
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode("utf-8", "replace") if isinstance(e.stderr, bytes) else e.stderr
        fail(f"git {' '.join(e.cmd[1:])} failed: {(stderr or '').strip()}")
    except Exception as e:  # every failure names itself in an annotation
        fail(f"unexpected {type(e).__name__}: {e}")
    print(f"release-notes: {counts['open-source']} open source and "
          f"{counts['commercial']} commercial changes between {prev} and "
          f"{env['VERSION']}")


if __name__ == "__main__":
    main()

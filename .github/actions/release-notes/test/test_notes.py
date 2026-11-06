from __future__ import annotations

import importlib.util
import re
import subprocess
import time
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "notes.py"
PREFIX = "staging/oss"
OSS_SHA = "b8bbb98ad641e4aba2343d48fbd819e8ca030a71"


def load():
    spec = importlib.util.spec_from_file_location("release_notes", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def commit(repo: Path, message: str | bytes, *paths: str) -> str:
    """A commit that appends to each path, so it lands in the sections those
    paths decide. The message goes through a file, so any byte survives."""
    for path in paths or ("pro.txt",):
        f = repo / path
        f.parent.mkdir(parents=True, exist_ok=True)
        with f.open("a") as out:
            out.write("x\n")
        git(repo, "add", path)
    msg = repo.parent / "msg"
    msg.write_bytes(message if isinstance(message, bytes) else message.encode())
    git(repo, "commit", "-q", "--allow-empty-message", "--cleanup=verbatim", "-F", str(msg))
    return git(repo, "rev-parse", "HEAD")


@pytest.fixture
def repo(tmp_path, monkeypatch):
    r = tmp_path / "repo"
    r.mkdir()
    git(r, "init", "-q", "-b", "main")
    git(r, "config", "user.email", "t@example.com")
    git(r, "config", "user.name", "t")
    commit(r, "initial", f"{PREFIX}/a.go")
    git(r, "tag", "v1.0.0")
    monkeypatch.chdir(r)
    monkeypatch.setenv("GITHUB_SERVER_URL", "https://github.com")
    return r


@pytest.fixture
def env(tmp_path, monkeypatch):
    out = tmp_path / "github_output"
    out.write_text("")
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))
    for k, v in {"VERSION": "v1.1.0", "SUBTREE_PREFIX": PREFIX,
                 "REPOSITORY": "o/mono", "OSS_REPOSITORY": "o/oss"}.items():
        monkeypatch.setenv(k, v)
    monkeypatch.delenv("PREVIOUS_TAG", raising=False)
    return out


def outputs(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)


def build(version="v1.1.0", override="", prefix=PREFIX):
    return load().build(version, override, prefix, "o/mono", "o/oss")


def raw_entries(body: str, section: str) -> list[str]:
    """The bullet lines under one ### section, as written."""
    if f"### {section}\n\n" not in body:
        return []
    lines = body.split(f"### {section}\n\n", 1)[1].split("\n\n", 1)[0]
    # Not splitlines(): it also splits on the separator bytes a subject holds.
    return lines.rstrip("\n").split("\n")


# A public entry: an inline code span, then the links the action adds.
SPAN = re.compile(r"^\* (`+)(.+?)(?<!`)\1(?!`)( \(\[.*)?$")


def plain(line: str) -> str:
    """An entry as a reader sees it: a code span unwrapped the way CommonMark
    reads it, and no invisible word joiners."""
    match = SPAN.match(line)
    if not match:
        return line.replace("\u2060", "")
    text = match.group(2)
    if len(text) > 1 and text[0] == text[-1] == " " and text.strip():
        text = text[1:-1]
    return f"* {text}{match.group(3) or ''}"


def entries(body: str, section: str) -> list[str]:
    return [plain(line) for line in raw_entries(body, section)]


def subjects(body: str, section: str) -> list[str]:
    """Entries without their trailing commit links."""
    return [e.split(" ([")[0] for e in entries(body, section)]


def run_main(capsys) -> tuple[int, str]:
    with pytest.raises(SystemExit) as e:
        load().main()
    return e.value.code, capsys.readouterr().out


# sections

def test_splits_by_subtree_oldest_first(repo):
    commit(repo, "fix: oss one (#10)", f"{PREFIX}/a.go")
    commit(repo, "feat: pro one (#11)")
    commit(repo, "fix: both trees (#12)", f"{PREFIX}/b.go", "pro.txt")
    commit(repo, "chore: oss two", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    prev, private, public, counts = build()
    assert prev == "v1.0.0"
    assert counts == {"open-source": 3, "commercial": 1}
    assert subjects(private, "Open source") == [
        "* fix: oss one (#10)", "* fix: both trees (#12)", "* chore: oss two"]
    assert entries(public, "Open source") == [
        "* fix: oss one", "* fix: both trees", "* chore: oss two"]
    assert entries(public, "Commercial") == ["* feat: pro one"]


def test_private_lines_link_the_monorepo_commit(repo):
    sha = commit(repo, "feat: pro one (#11)")
    git(repo, "tag", "v1.1.0")
    _, private, _, _ = build()
    assert entries(private, "Commercial") == [
        f"* feat: pro one (#11) ([{sha[:10]}](https://github.com/o/mono/commit/{sha}))"]
    assert private.rstrip().endswith(
        "**Full Changelog**: https://github.com/o/mono/compare/v1.0.0...v1.1.0")


def test_no_changes(repo):
    commit(repo, "docs: readme")
    git(repo, "tag", "v1.1.0")
    _, private, public, counts = build()
    assert counts == {"open-source": 0, "commercial": 0}
    assert "No changes." in public and "No changes." in private


# the subtree prefix

@pytest.mark.parametrize("prefix", [PREFIX, f"{PREFIX}/", f"./{PREFIX}"])
def test_prefix_spellings_of_the_subtree(repo, prefix):
    commit(repo, "fix: oss", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    assert build(prefix=prefix)[3] == {"open-source": 1, "commercial": 0}


@pytest.mark.parametrize("prefix, reason", [
    ("staging/osss", "is not a directory at v1.1.0"),
    (f"{PREFIX}/a.go", "is not a directory at v1.1.0"),
    (".", "names the repository root"),
    ("./", "names the repository root"),
    ("/", "names the repository root"),
    ("../staging/oss", "names the repository root"),
])
def test_a_prefix_that_is_not_a_subtree_fails(repo, prefix, reason):
    """A typo would list every OSS change under Commercial, and the root would
    list every change under Open source, both with the step green."""
    commit(repo, "fix: oss", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    mod = load()
    with pytest.raises(mod.NotesError, match=reason):
        mod.build("v1.1.0", "", prefix, "o/mono", "o/oss")


# public body: no refs into the monorepo

def test_public_notes_carry_no_monorepo_refs(repo):
    commit(repo, "Revert \"fix: x (#7)\" (#8)")
    commit(repo, "Merge pull request #9 from o/branch")
    commit(repo, "fix: follow up on o/oss#4040 (#13)")
    git(repo, "tag", "v1.1.0")
    _, _, public, _ = build()
    assert entries(public, "Commercial") == [
        "* Revert \"fix: x\"",
        "* Merge pull request 9 from o/branch",
        "* fix: follow up on o/oss#4040",
    ]
    assert "compare" not in public
    assert "o/mono" not in public


@pytest.mark.parametrize("subject, public", [
    ("fix: follow up on o/mono#4040 (#4100)", "fix: follow up on"),
    ("fix: x (o/mono#12)", "fix: x"),
    ("fix: see O/Mono#12 too", "fix: see too"),
    ("fix: x https://github.com/o/mono/pull/2058", "fix: x"),
    ("fix: x (https://github.com/o/mono/pull/2058)", "fix: x"),
    ("fix: revert o/mono@abc1234", "fix: revert"),
    ("fix: x (GH-123)", "fix: x"),
    ("fix: x for GH-123", "fix: x for 123"),
    ("fix: port from https://github.com/o/mono", "fix: port from"),
    ("fix: see https://github.com/o/mono#readme now", "fix: see now"),
    ("fix: port from o/mono@main", "fix: port from"),
    ("fix: x (o/mono#12 and #13)", "fix: x"),
    ("fix: x (#12, #13)", "fix: x"),
    ("fix: x https://github.com/o/mono/blob/main/a(b).go now", "fix: x now"),
    ("fix: keep o/mono-docs#1 and o/oss#2", "fix: keep o/mono-docs#1 and o/oss#2"),
    ("fix: keep the name o/mono in prose", "fix: keep the name o/mono in prose"),
    ("fix: x www.github.com/o/mono/pull/12", "fix: x"),
    ("fix: see https://github.com/o/mono.", "fix: see"),
    ("fix: clone https://github.com/o/mono.git now", "fix: clone now"),
    ("fix: x https://api.github.com/repos/o/mono/pulls/1", "fix: x"),
    ("fix: x <https://github.com/o/mono/pull/1>", "fix: x"),
    ("fix: x (https://github.com/o/mono/blob/main/a(b).go)", "fix: x"),
    ("fix: keep https://github.com/o/mono-docs/pull/1", "fix: keep https://github.com/o/mono-docs/pull/1"),
    ("fix: keep https://github.com/o/oss/pull/1", "fix: keep https://github.com/o/oss/pull/1"),
])
def test_public_notes_drop_every_form_of_monorepo_ref(repo, subject, public):
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    _, private, body, _ = build()
    assert entries(body, "Commercial") == [f"* {public}"]
    assert subjects(private, "Commercial") == [f"* {subject}"]


# commits imported from OSS

def test_imported_oss_commit_links_its_oss_commit(repo):
    """The subject carries an OSS PR ref and the ref of the monorepo PR that
    merged the import; neither can be told apart, so both go and the OSS
    commit is linked. The trailer sits outside git's trailer block."""
    sha = commit(repo, "fix(x): y (#4084) (#2058)\n\n"
                       f"Oss-Commit: {OSS_SHA}\n\nCo-authored-by: a <a@b.c>\n",
                 f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    _, private, public, _ = build()
    oss_link = f"(https://github.com/o/oss/commit/{OSS_SHA})"
    assert entries(public, "Open source") == [f"* fix(x): y ([{OSS_SHA[:10]}]{oss_link})"]
    assert entries(private, "Open source") == [
        f"* fix(x): y ([{sha[:10]}](https://github.com/o/mono/commit/{sha}), "
        f"[o/oss@{OSS_SHA[:10]}]{oss_link})"]


def test_bulk_import_links_no_oss_commit(repo):
    commit(repo, "chore: sync from o/oss (#2177)\n\n"
                 f"Oss-Commit: {OSS_SHA}\nOss-Commit: {'1' * 40}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    _, private, public, _ = build()
    assert entries(public, "Open source") == ["* chore: sync from o/oss"]
    assert "o/oss/commit" not in private


@pytest.mark.parametrize("trailer", [
    f"Oss-Commit: {OSS_SHA}",
    f"Oss-Commit : {OSS_SHA}",
    f"Oss-Commit:\t{OSS_SHA}",
    f"Oss-Commit:{OSS_SHA}",
    f"oss-commit: {OSS_SHA.upper()}",
    f"Oss-Commit: {OSS_SHA}\r",
    f"Oss-Commit: {OSS_SHA}   ",
    f"Oss-Commit: {OSS_SHA[:7]}",
    f"Oss-Commit: {OSS_SHA}\n   \nSigned-off-by: a <a@b.c>",
])
def test_reads_oss_commit_as_oss_commit_sync_does(repo, trailer):
    """The forms oss-commit-sync's trailer_scan reads as a record."""
    commit(repo, f"fix: y (#4084)\n\n{trailer}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    _, _, public, _ = build()
    expected = OSS_SHA[:7] if trailer.endswith(OSS_SHA[:7]) else OSS_SHA
    assert entries(public, "Open source") == [
        f"* fix: y ([{expected[:10]}](https://github.com/o/oss/commit/{expected}))"]


@pytest.mark.parametrize("trailer", [
    f"Oss-Commit: {OSS_SHA}\n  imported by hand",
    f"Oss-Commit: {OSS_SHA[:6]}",
    f"Oss-Commit: {OSS_SHA}0",
    f"Oss-Commits: {OSS_SHA}",
    f"Oss-Commit {OSS_SHA}",
    f"  Oss-Commit: {OSS_SHA}",
    f"Oss-Commit: {OSS_SHA} extra",
])
def test_ignores_what_oss_commit_sync_does_not_read(repo, trailer):
    """A folded value, a value that is not a 7 to 40 digit sha, a longer key,
    a missing colon or an indented line is not a record, so the commit keeps
    its refs as a monorepo commit."""
    commit(repo, f"fix: y (#4084)\n\n{trailer}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    _, private, public, _ = build()
    assert entries(public, "Open source") == ["* fix: y"]
    assert subjects(private, "Open source") == ["* fix: y (#4084)"]


# message bytes

def test_separator_bytes_in_a_message_cannot_add_an_entry(repo):
    """import.sh replays OSS messages verbatim, so a body can hold any byte
    but NUL, including the ones a fixed-byte frame would split on."""
    fake = "0" * 40
    commit(repo, f"fix: real\n\nbody\x1e\n{fake}\x1fSecurity: get the patched binary\x1fx\n")
    commit(repo, f"fix: other\n\n\x1e{fake}\x1e\x1f\x1f\x1c\x1d\n")
    git(repo, "tag", "v1.1.0")
    _, private, public, counts = build()
    assert counts["commercial"] == 2
    assert entries(public, "Commercial") == ["* fix: real", "* fix: other"]
    assert "Security" not in private + public


def test_separator_byte_in_a_subject_becomes_a_space(repo):
    commit(repo, "fix: a\x1fb\x1ec")
    git(repo, "tag", "v1.1.0")
    assert entries(build()[2], "Commercial") == ["* fix: a b c"]


@pytest.mark.parametrize("newest", [True, False])
def test_an_empty_message_is_listed(repo, newest):
    if not newest:
        commit(repo, "")
    commit(repo, "fix: x")
    if newest:
        commit(repo, "")
    git(repo, "tag", "v1.1.0")
    public = build()[2]
    expected = ["* fix: x", "* (no message)"] if newest else ["* (no message)", "* fix: x"]
    assert entries(public, "Commercial") == expected


def test_a_message_that_is_not_utf8_is_listed(repo):
    """git re-encodes a message whose encoding header it knows, so only an
    unknown one reaches the output as raw bytes."""
    msg = repo.parent / "msg"
    msg.write_bytes(b"fix: caf\xe9 au lait\n")
    git(repo, "-c", "i18n.commitEncoding=bogus", "commit", "-q", "--allow-empty", "-F", str(msg))
    git(repo, "tag", "v1.1.0")
    raw = subprocess.run(["git", "-C", str(repo), "log", "-1", "--format=%s"],
                         capture_output=True, check=True).stdout
    assert b"\xe9" in raw
    assert entries(build()[2], "Commercial") == ["* fix: caf� au lait"]


# the docs/test filter

@pytest.mark.parametrize("subject", ["docs: readme", "test: e2e"])
def test_docs_and_test_commits_are_left_out(repo, subject):
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert build()[3] == {"open-source": 0, "commercial": 0}


@pytest.mark.parametrize("subject", [
    "docs(readme): fields", "test(e2e): fix flaky specs", "test(e2e)!: rework",
    "Docs: readme", "testing: harness", "docsite: rebuild"])
def test_only_the_goreleaser_filter_forms_are_left_out(repo, subject):
    """The goreleaser filters these notes replace were ^docs: and ^test:."""
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert build()[3]["commercial"] == 1


# base tag

def test_stable_compares_with_previous_stable(repo):
    commit(repo, "fix: in rc")
    git(repo, "tag", "v1.1.0-rc.1")
    commit(repo, "fix: after rc")
    git(repo, "tag", "v1.1.0")
    prev, _, public, _ = build()
    assert prev == "v1.0.0"
    assert entries(public, "Commercial") == ["* fix: in rc", "* fix: after rc"]


def test_prerelease_compares_with_previous_tag(repo):
    commit(repo, "fix: in rc")
    git(repo, "tag", "v1.1.0-rc.1")
    commit(repo, "fix: after rc")
    git(repo, "tag", "v1.1.0-rc.2")
    prev, _, public, _ = build("v1.1.0-rc.2")
    assert prev == "v1.1.0-rc.1"
    assert entries(public, "Commercial") == ["* fix: after rc"]


def test_next_tags_are_never_the_base(repo):
    commit(repo, "fix: one")
    git(repo, "tag", "v1.1.0-next.internal.1")
    commit(repo, "fix: two")
    git(repo, "tag", "v1.1.0-alpha.1")
    assert build("v1.1.0-alpha.1")[0] == "v1.0.0"


# body size

def test_bodies_fit_the_byte_limit_and_keep_the_newest(repo, monkeypatch):
    for i in range(30):
        commit(repo, f"fix: change number {i:02d} with some length to it")
    git(repo, "tag", "v1.1.0")
    mod = load()
    monkeypatch.setattr(mod, "MAX_BODY_BYTES", 2000)
    _, private, public, counts = mod.build("v1.1.0", "", PREFIX, "o/mono", "o/oss")
    assert len(private.encode()) <= 2000
    assert len(public.encode()) <= 2000
    listed = subjects(private, "Commercial")
    assert listed == entries(public, "Commercial")
    assert listed[-1] == "* fix: change number 29 with some length to it"
    assert f"{30 - len(listed)} earlier changes are not listed." in public
    assert private.rstrip().endswith("compare/v1.0.0...v1.1.0")
    assert counts["commercial"] == len(listed)


def test_body_limit_counts_bytes_not_characters(repo, monkeypatch):
    for i in range(20):
        commit(repo, f"fix: {i:02d} " + "é" * 40)
    git(repo, "tag", "v1.1.0")
    mod = load()
    monkeypatch.setattr(mod, "MAX_BODY_BYTES", 1500)
    _, private, public, _ = mod.build("v1.1.0", "", PREFIX, "o/mono", "o/oss")
    assert len(private.encode()) <= 1500 and len(public.encode()) <= 1500


def test_body_under_the_limit_lists_everything(repo):
    for i in range(5):
        commit(repo, f"fix: {i}")
    git(repo, "tag", "v1.1.0")
    _, _, public, _ = build()
    assert len(entries(public, "Commercial")) == 5
    assert "not listed" not in public


def test_the_limit_is_githubs():
    assert load().MAX_BODY_BYTES <= 125_000


# main

def test_main_writes_both_files(repo, env):
    commit(repo, "fix: oss (#1)", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    load().main()
    out = outputs(env)
    assert out["previous-tag"] == "v1.0.0"
    assert out["open-source-count"] == "1"
    assert out["commercial-count"] == "0"
    assert "(#1)" in Path(out["notes-file"]).read_text()
    assert Path(out["public-notes-file"]).read_text().startswith("## Changelog\n")


def test_missing_tag_fails(repo, env, capsys):
    code, out = run_main(capsys)
    assert code == 1
    assert "::error::release-notes: tag v1.1.0 is not in the checkout" in out


def test_first_release_fails(repo, env, monkeypatch, capsys):
    monkeypatch.setenv("VERSION", "v1.0.0")
    code, out = run_main(capsys)
    assert code == 1
    assert "nothing to compare against" in out


def test_missing_override_fails(repo, env, monkeypatch, capsys):
    commit(repo, "fix: x")
    git(repo, "tag", "v1.1.0")
    monkeypatch.setenv("PREVIOUS_TAG", "v0.9.0")
    code, out = run_main(capsys)
    assert code == 1
    assert "previous tag 'v0.9.0' is not in the checkout" in out


def test_bad_prefix_fails_in_main(repo, env, monkeypatch, capsys):
    commit(repo, "fix: x")
    git(repo, "tag", "v1.1.0")
    monkeypatch.setenv("SUBTREE_PREFIX", "staging/osss")
    code, out = run_main(capsys)
    assert code == 1
    assert "::error::release-notes: subtree-prefix 'staging/osss' is not a directory" in out


def test_unexpected_error_fails_with_an_annotation(repo, env, monkeypatch, capsys):
    """Every failure names itself in an ::error:: line, not only a traceback."""
    commit(repo, "fix: x")
    git(repo, "tag", "v1.1.0")
    mod = load()
    monkeypatch.setattr(mod, "list_commits", lambda *a: 1 / 0)
    with pytest.raises(SystemExit) as e:
        mod.main()
    assert e.value.code == 1
    assert "::error::release-notes: unexpected ZeroDivisionError" in capsys.readouterr().out


@pytest.mark.parametrize("key, value", [
    ("VERSION", ""), ("SUBTREE_PREFIX", ""), ("REPOSITORY", "mono"), ("OSS_REPOSITORY", "")])
def test_missing_input_fails(repo, env, monkeypatch, capsys, key, value):
    monkeypatch.setenv(key, value)
    code, out = run_main(capsys)
    assert code == 1
    assert key in out


def test_shallow_checkout_fails(tmp_path, env, monkeypatch, capsys, repo):
    commit(repo, "fix: x")
    git(repo, "tag", "v1.1.0")
    clone = tmp_path / "shallow"
    subprocess.run(["git", "clone", "-q", "--depth=1", f"file://{repo}", str(clone)],
                   check=True, capture_output=True)
    monkeypatch.chdir(clone)
    code, out = run_main(capsys)
    assert code == 1
    assert "shallow" in out


# mentions

WJ = "⁠"


@pytest.mark.parametrize("subject, rendered", [
    ("ci: pin @v1 to @detect-changes/v1", f"ci: pin @{WJ}v1 to @{WJ}detect-changes/v1"),
    ("chore: thanks @octo-cat", f"chore: thanks @{WJ}octo-cat"),
    ("@bot: start of subject", f"@{WJ}bot: start of subject"),
    ("fix: ping (@org/team)", f"fix: ping (@{WJ}org/team)"),
    ("fix: mail a@b.com and uses: x/y@v4", "fix: mail a@b.com and uses: x/y@v4"),
    ("fix: lone @ sign and @@", "fix: lone @ sign and @@"),
])
def test_subjects_mention_nobody(repo, subject, rendered):
    """A word joiner after @ stops GitHub reading a subject as a mention,
    which would notify that account and list it as a contributor."""
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    _, private, public, _ = build()
    assert [e.split(" ([")[0] for e in raw_entries(private, "Commercial")] == [f"* {rendered}"]
    assert SPAN.match(raw_entries(public, "Commercial")[0])


def test_imported_subjects_mention_nobody(repo):
    commit(repo, f"fix: thanks @someone (#4084)\n\nOss-Commit: {OSS_SHA}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    _, private, public, _ = build()
    assert f"@{WJ}someone" in private and "@someone" not in private
    assert raw_entries(public, "Open source")[0].startswith("* `fix: thanks @someone` ([")


LIB_SH = Path(__file__).resolve().parents[2] / "oss-commit-sync" / "lib.sh"


def trailer_scan(repo: Path) -> set[str]:
    """What oss-commit-sync reads as Oss-Commit records on HEAD."""
    out = subprocess.run(
        ["bash", "-c", f'source "{LIB_SH}" && trailer_scan Oss-Commit 1 -1 HEAD'],
        cwd=repo, capture_output=True, text=True, check=True).stdout
    return {line.split()[1] for line in out.splitlines()}


@pytest.mark.parametrize("trailers", [
    f"Oss-Commit: {OSS_SHA}",
    f"Oss-Commit : {OSS_SHA}",
    f"Oss-Commit:\t{OSS_SHA}",
    f"Oss-Commit:{OSS_SHA}",
    f"oss-commit: {OSS_SHA.upper()}",
    f"Oss-Commit: {OSS_SHA}\r",
    f"Oss-Commit: {OSS_SHA}   ",
    f"Oss-Commit: {OSS_SHA[:7]}",
    f"Oss-Commit: {OSS_SHA}\n   \nSigned-off-by: a <a@b.c>",
    f"Oss-Commit: {OSS_SHA}\n  imported by hand",
    f"Oss-Commit:\n  {OSS_SHA}",
    f"Oss-Commit: \n\t{OSS_SHA}",
    f"Oss-Commit: {OSS_SHA[:6]}",
    f"Oss-Commit: {OSS_SHA}0",
    f"Oss-Commits: {OSS_SHA}",
    f"Oss-Commit {OSS_SHA}",
    f"Oss-Commit: {OSS_SHA} extra",
    f"Oss-Commit: {OSS_SHA}\nOss-Commit: {'1' * 40}",
    f"Oss-Commit: {OSS_SHA}\n\nCo-authored-by: a <a@b.c>",
    f"see\nOss-Commit: {OSS_SHA}\nin the body\n\nSigned-off-by: a <a@b.c>",
])
def test_reads_the_records_trailer_scan_reads(repo, trailers):
    """The release notes and the sync must agree on which commits are
    imports, so every form is checked against trailer_scan itself."""
    commit(repo, f"fix: y (#4084)\n\n{trailers}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    read = load().list_commits("v1.0.0", "v1.1.0")[-1]["oss_commits"]
    assert set(read) == trailer_scan(repo)


@pytest.mark.parametrize("subject", [
    "fix(syncer): backport fixes (" + " ".join(f"#{n}" for n in range(101, 141)) + " and others)",
    "fix: (" + " ".join(f"o/mono#{n}" for n in range(1, 41)) + " x)",
    "fix: (" + " " * 40000 + "x",
    "fix: " + " " * 40000 + "o/mono",
    "fix: " + "https://github.com/" * 4000,
])
def test_ref_stripping_is_linear(subject):
    """A replayed OSS subject must not stall the step that gates the release."""
    mod = load()
    start = time.monotonic()
    mod.without_refs(subject, mod.ref_patterns("o/mono"))
    mod.without_refs(subject)
    assert time.monotonic() - start < 1


@pytest.mark.parametrize("subject", [
    "fix(snapshot): use t.Context() instead of background context",
    "fix: call Close() on the response body",
])
def test_ordinary_parentheses_stay(repo, subject):
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert entries(build()[2], "Commercial") == [f"* {subject}"]


@pytest.mark.parametrize("subject", [
    "fix x gh-13", "Gh-14 y", "x-#12", "x.#12", "_#12_", "fix x (#12/#13)",
    "_o/mono#12_", "github.com/o/mono/pull/12", "github.com/o/mono#12",
    "GitHub.com/o/mono/pull/3", "ftp://github.com/o/mono/pull/1",
    "https://github.com/o/./mono/pull/12", "o/mono/pull/12", "o/mono/issues/4",
    "o/mono/commit/6d15355ec", "repo@1234567abc", "see https://example.com/x",
    "x/y#5", "www.example.com", "@octocat",
])
def test_public_subjects_link_nothing(repo, subject):
    """Whatever stripping leaves sits in a code span, where GitHub links,
    mentions and formats nothing."""
    commit(repo, f"fix: {subject}")
    git(repo, "tag", "v1.1.0")
    match = SPAN.match(raw_entries(build()[2], "Commercial")[0])
    assert match and match.group(3) is None
    assert entries(build()[2], "Commercial")[0].startswith("* fix:")


def test_public_code_span_keeps_the_oss_commit_link(repo):
    commit(repo, f"fix: y\n\nOss-Commit: {OSS_SHA}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    assert raw_entries(build()[2], "Open source") == [
        f"* `fix: y` ([{OSS_SHA[:10]}](https://github.com/o/oss/commit/{OSS_SHA}))"]


def test_imported_commits_drop_lowercase_gh_refs_in_the_private_body(repo):
    commit(repo, f"fix: y gh-13 (gh-14)\n\nOss-Commit: {OSS_SHA}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    assert subjects(build()[1], "Open source") == ["* fix: y 13"]


def test_a_huge_subject_is_capped_and_fast(repo):
    commit(repo, "fix: " + "www." * 32000)
    git(repo, "tag", "v1.1.0")
    start = time.monotonic()
    _, private, public, _ = build()
    assert time.monotonic() - start < 2
    line = entries(public, "Commercial")[0]
    assert len(line) <= 302 and line.endswith("\u2026")


@pytest.mark.parametrize("subject", [
    "fix: use `foo` here", "`leading tick", "trailing tick`", "a ``` b", "``",
    "fix: [click](https://evil.example.com) <img src=x.png> &#x40;octocat",
])
def test_public_subjects_round_trip_through_a_code_span(repo, subject):
    """Whatever a subject holds, it renders as the same literal text."""
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    raw = raw_entries(build()[2], "Commercial")[0]
    assert SPAN.match(raw)
    assert entries(build()[2], "Commercial") == [f"* {subject}"]


@pytest.mark.parametrize("subject, rendered", [
    ("fix: thanks _@octocat_", f"fix: thanks _@{WJ}octocat_"),
    ("fix: thanks @@octocat", f"fix: thanks @@{WJ}octocat"),
    ("fix: thanks é@octocat", f"fix: thanks é@{WJ}octocat"),
    ("fix: thanks &#x40;octocat & co", "fix: thanks &amp;#x40;octocat & co"),
])
def test_private_subjects_mention_nobody(repo, subject, rendered):
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert [e.split(" ([")[0] for e in raw_entries(build()[1], "Commercial")] == [f"* {rendered}"]


def test_imported_refs_after_punctuation_drop_in_the_private_body(repo):
    commit(repo, f"fix: y _#12_ x.#13\n\nOss-Commit: {OSS_SHA}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    assert subjects(build()[1], "Open source") == ["* fix: y _12_ x.13"]


@pytest.mark.parametrize("separator", ["\r", "\r\r", "\x0b", "\x0c", "\x85", " ", " ", "\x1d"])
def test_a_subject_is_one_line_in_both_bodies(repo, separator):
    """CommonMark ends a line at a bare CR, which would close the code span
    and let the rest of a replayed subject render as markdown."""
    subject = f"fix a{separator}@octocat [x](https://evil.example) <img src=x>{separator}# Heading"
    commit(repo, subject.encode())
    git(repo, "tag", "v1.1.0")
    _, private, public, _ = build()
    for body in (private, public):
        assert not re.search(r"[\r\x0b\x0c\x85  \x1c-\x1f]", body)
    raw = raw_entries(public, "Commercial")
    assert len(raw) == 1 and SPAN.match(raw[0])


@pytest.mark.parametrize("run", [4, 79, 80, 200])
def test_long_backtick_runs_keep_the_fence_short(repo, run):
    """GitHub stops matching a code span fence of about 80 backticks."""
    commit(repo, "fix " + "`" * run + " @octocat")
    git(repo, "tag", "v1.1.0")
    raw = raw_entries(build()[2], "Commercial")[0]
    match = SPAN.match(raw)
    assert match and len(match.group(1)) <= 4
    assert entries(build()[2], "Commercial") == ["* fix ``` @octocat"]


@pytest.mark.parametrize("subject, rendered", [
    ("fix: see https://example.com/?a=1&b=2", "fix: see https://example.com/?a=1&b=2"),
    ("fix: R&D and AT&T", "fix: R&D and AT&T"),
    ("fix: &commat;hubot &#64;x &#x23;12", "fix: &amp;commat;hubot &amp;#64;x &amp;#x23;12"),
])
def test_private_escapes_only_entities(repo, subject, rendered):
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert [e.split(" ([")[0] for e in raw_entries(build()[1], "Commercial")] == [f"* {rendered}"]


@pytest.mark.parametrize("subject, rendered", [
    ("<div>thanks &#64octocat</div>", "<div>thanks &amp;#64octocat</div>"),
    ("<details>&#x40octocat &#X40;hubot</details>", "<details>&amp;#x40octocat &amp;#X40;hubot</details>"),
])
def test_private_escapes_numeric_entities_without_a_semicolon(repo, subject, rendered):
    """Inside an HTML block GitHub decodes &#64 even without its semicolon."""
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert [e.split(" ([")[0] for e in raw_entries(build()[1], "Commercial")] == [f"* {rendered}"]


@pytest.mark.parametrize("control", ["‮", "‪", "⁦", "⁩", "‎", "‏", "؜"])
def test_bidi_controls_cannot_reorder_the_links(repo, control):
    """An unclosed override flows out of the subject and shows the commit
    links after it reversed."""
    commit(repo, f"fix: bump client-go {control}\n\nOss-Commit: {OSS_SHA}\n", f"{PREFIX}/a.go")
    git(repo, "tag", "v1.1.0")
    _, private, public, _ = build()
    assert not re.search("[؜‎‏‪-‮⁦-⁩]", private + public)


@pytest.mark.parametrize("subject", [
    "fix `&#` prefix check", "handle `&#x27` without semicolon",
    "see https://example.com/page?a=1&#frag",
])
def test_private_keeps_a_numeric_entity_shape_outside_html(repo, subject):
    """Without HTML GitHub does not decode &# with no semicolon, and code
    spans and bare URLs would show an escape literally."""
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert [e.split(" ([")[0] for e in raw_entries(build()[1], "Commercial")] == [f"* {subject}"]

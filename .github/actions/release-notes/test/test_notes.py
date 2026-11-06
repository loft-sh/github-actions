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
    """A commit that appends to each path, in the subtree unless paths say
    otherwise. The message goes through a file, so any byte survives."""
    for path in paths or (f"{PREFIX}/a.go",):
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
    commit(r, "initial")
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


def body(**kwargs) -> str:
    return build(**kwargs)[1]


def raw_entries(text: str) -> list[str]:
    """The bullet lines, as written."""
    # Not splitlines(): it also splits on the separator bytes a subject holds.
    return [line for line in text.split("\n") if line.startswith("* ")]


# An entry: an inline code span, then the link the action adds.
SPAN = re.compile(r"^\* (`+)(.+?)(?<!`)\1(?!`)( \(\[.*)?$")


def plain(line: str) -> str:
    """An entry as a reader sees it: the code span unwrapped the way
    CommonMark reads it."""
    match = SPAN.match(line)
    if not match:
        return line
    text = match.group(2)
    if len(text) > 1 and text[0] == text[-1] == " " and text.strip():
        text = text[1:-1]
    return f"* {text}{match.group(3) or ''}"


def entries(text: str) -> list[str]:
    return [plain(line) for line in raw_entries(text)]


def run_main(capsys) -> tuple[int, str]:
    with pytest.raises(SystemExit) as e:
        load().main()
    return e.value.code, capsys.readouterr().out


# what is listed

def test_lists_only_subtree_commits_oldest_first(repo):
    commit(repo, "fix: oss one (#10)")
    commit(repo, "feat: pro one (#11)", "pro.txt")
    commit(repo, "fix: both trees (#12)", f"{PREFIX}/b.go", "pro.txt")
    commit(repo, "chore: oss two")
    git(repo, "tag", "v1.1.0")
    prev, text, count = build()
    assert prev == "v1.0.0"
    assert count == 3
    assert entries(text) == ["* fix: oss one", "* fix: both trees", "* chore: oss two"]
    assert "pro one" not in text
    assert text.startswith("## Changelog\n\nChanges since v1.0.0.\n\n* ")


def test_lists_what_oss_commit_sync_exports(repo):
    """The same first-parent rev-list the export runs, so a commit merged in
    from a side branch counts only through its merge."""
    commit(repo, "fix: on main")
    git(repo, "checkout", "-q", "-b", "side")
    commit(repo, "fix: on side")
    git(repo, "checkout", "-q", "main")
    commit(repo, "feat: pro", "pro.txt")
    git(repo, "merge", "-q", "--no-ff", "-m", "Merge branch side", "side")
    git(repo, "tag", "v1.1.0")
    exported = git(repo, "rev-list", "--first-parent", "--reverse", "v1.0.0..v1.1.0", "--", PREFIX)
    subjects = [git(repo, "log", "-1", "--format=%s", sha) for sha in exported.split()]
    assert entries(body()) == [f"* {s}" for s in subjects]
    assert entries(body()) == ["* fix: on main", "* Merge branch side"]


def test_no_changes(repo):
    commit(repo, "docs: readme")
    commit(repo, "feat: pro", "pro.txt")
    git(repo, "tag", "v1.1.0")
    _, text, count = build()
    assert count == 0
    assert "No changes." in text
    assert "pro" not in text


# the subtree prefix

@pytest.mark.parametrize("prefix", [PREFIX, f"{PREFIX}/", f"./{PREFIX}"])
def test_prefix_spellings_of_the_subtree(repo, prefix):
    commit(repo, "fix: oss")
    git(repo, "tag", "v1.1.0")
    assert build(prefix=prefix)[2] == 1


@pytest.mark.parametrize("prefix, reason", [
    ("staging/osss", "is not a directory at v1.1.0"),
    (f"{PREFIX}/a.go", "is not a directory at v1.1.0"),
    (".", "names the repository root"),
    ("./", "names the repository root"),
    ("/", "names the repository root"),
    ("../staging/oss", "names the repository root"),
])
def test_a_prefix_that_is_not_a_subtree_fails(repo, prefix, reason):
    """A typo would publish an empty changelog, and the root would publish
    every commercial change, both with the step green."""
    commit(repo, "fix: oss")
    git(repo, "tag", "v1.1.0")
    mod = load()
    with pytest.raises(mod.NotesError, match=reason):
        mod.build("v1.1.0", "", prefix, "o/mono", "o/oss")


# no refs into the monorepo

def test_carries_no_monorepo_refs(repo):
    commit(repo, "Revert \"fix: x (#7)\" (#8)")
    commit(repo, "Merge pull request #9 from o/branch")
    commit(repo, "fix: follow up on o/oss#4040 (#13)")
    git(repo, "tag", "v1.1.0")
    text = body()
    assert entries(text) == [
        "* Revert \"fix: x\"",
        "* Merge pull request 9 from o/branch",
        "* fix: follow up on o/oss#4040",
    ]
    assert "compare" not in text
    assert "o/mono" not in text


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
    ("fix: y gh-13 (gh-14)", "fix: y 13"),
    ("fix: y _#12_ x.#13", "fix: y _12_ x.13"),
])
def test_drops_every_form_of_monorepo_ref(repo, subject, public):
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert entries(body()) == [f"* {public}"]


# commits imported from OSS

def test_imported_oss_commit_links_its_oss_commit(repo):
    """The subject carries an OSS PR ref and the ref of the monorepo PR that
    merged the import; neither can be told apart, so both go and the OSS
    commit is linked. The trailer sits outside git's trailer block."""
    commit(repo, "fix(x): y (#4084) (#2058)\n\n"
                 f"Oss-Commit: {OSS_SHA}\n\nCo-authored-by: a <a@b.c>\n")
    git(repo, "tag", "v1.1.0")
    assert raw_entries(body()) == [
        f"* `fix(x): y` ([{OSS_SHA[:10]}](https://github.com/o/oss/commit/{OSS_SHA}))"]


def test_bulk_import_links_no_oss_commit(repo):
    commit(repo, "chore: sync from o/oss (#2177)\n\n"
                 f"Oss-Commit: {OSS_SHA}\nOss-Commit: {'1' * 40}\n")
    git(repo, "tag", "v1.1.0")
    text = body()
    assert entries(text) == ["* chore: sync from o/oss"]
    assert "o/oss/commit" not in text


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
    commit(repo, f"fix: y (#4084)\n\n{trailer}\n")
    git(repo, "tag", "v1.1.0")
    expected = OSS_SHA[:7] if trailer.endswith(OSS_SHA[:7]) else OSS_SHA
    assert entries(body()) == [
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
    a missing colon or an indented line is not a record, so the commit
    links no OSS commit."""
    commit(repo, f"fix: y (#4084)\n\n{trailer}\n")
    git(repo, "tag", "v1.1.0")
    assert raw_entries(body()) == ["* `fix: y`"]


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
    commit(repo, f"fix: y (#4084)\n\n{trailers}\n")
    git(repo, "tag", "v1.1.0")
    read = load().list_commits("v1.0.0", "v1.1.0", PREFIX)[-1]["oss_commits"]
    assert set(read) == trailer_scan(repo)


# message bytes

def test_separator_bytes_in_a_message_cannot_add_an_entry(repo):
    """import.sh replays OSS messages verbatim, so a body can hold any byte
    but NUL, including the ones a fixed-byte frame would split on."""
    fake = "0" * 40
    commit(repo, f"fix: real\n\nbody\x1e\n{fake}\x1fSecurity: get the patched binary\x1fx\n")
    commit(repo, f"fix: other\n\n\x1e{fake}\x1e\x1f\x1f\x1c\x1d\n")
    git(repo, "tag", "v1.1.0")
    _, text, count = build()
    assert count == 2
    assert entries(text) == ["* fix: real", "* fix: other"]
    assert "Security" not in text


def test_separator_byte_in_a_subject_becomes_a_space(repo):
    commit(repo, "fix: a\x1fb\x1ec")
    git(repo, "tag", "v1.1.0")
    assert entries(body()) == ["* fix: a b c"]


@pytest.mark.parametrize("newest", [True, False])
def test_an_empty_message_is_listed(repo, newest):
    if not newest:
        commit(repo, "")
    commit(repo, "fix: x")
    if newest:
        commit(repo, "")
    git(repo, "tag", "v1.1.0")
    expected = ["* fix: x", "* (no message)"] if newest else ["* (no message)", "* fix: x"]
    assert entries(body()) == expected


def test_a_message_that_is_not_utf8_is_listed(repo):
    """git re-encodes a message whose encoding header it knows, so only an
    unknown one reaches the output as raw bytes."""
    msg = repo.parent / "msg"
    msg.write_bytes(b"fix: caf\xe9 au lait\n")
    (repo / PREFIX / "a.go").write_text("changed\n")
    git(repo, "add", PREFIX)
    git(repo, "-c", "i18n.commitEncoding=bogus", "commit", "-q", "-F", str(msg))
    git(repo, "tag", "v1.1.0")
    raw = subprocess.run(["git", "-C", str(repo), "log", "-1", "--format=%s"],
                         capture_output=True, check=True).stdout
    assert b"\xe9" in raw
    assert entries(body()) == ["* fix: caf� au lait"]


# the docs/test filter

@pytest.mark.parametrize("subject", ["docs: readme", "test: e2e"])
def test_docs_and_test_commits_are_left_out(repo, subject):
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert build()[2] == 0


@pytest.mark.parametrize("subject", [
    "docs(readme): fields", "test(e2e): fix flaky specs", "test(e2e)!: rework",
    "Docs: readme", "testing: harness", "docsite: rebuild"])
def test_only_the_goreleaser_filter_forms_are_left_out(repo, subject):
    """The monorepo's goreleaser changelog filters ^docs: and ^test:."""
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert build()[2] == 1


# base tag

def test_stable_compares_with_previous_stable(repo):
    commit(repo, "fix: in rc")
    git(repo, "tag", "v1.1.0-rc.1")
    commit(repo, "fix: after rc")
    git(repo, "tag", "v1.1.0")
    prev, text, _ = build()
    assert prev == "v1.0.0"
    assert entries(text) == ["* fix: in rc", "* fix: after rc"]


def test_prerelease_compares_with_previous_tag(repo):
    commit(repo, "fix: in rc")
    git(repo, "tag", "v1.1.0-rc.1")
    commit(repo, "fix: after rc")
    git(repo, "tag", "v1.1.0-rc.2")
    prev, text, _ = build("v1.1.0-rc.2")
    assert prev == "v1.1.0-rc.1"
    assert entries(text) == ["* fix: after rc"]


def test_next_tags_are_never_the_base(repo):
    commit(repo, "fix: one")
    git(repo, "tag", "v1.1.0-next.internal.1")
    commit(repo, "fix: two")
    git(repo, "tag", "v1.1.0-alpha.1")
    assert build("v1.1.0-alpha.1")[0] == "v1.0.0"


# body size

def test_body_fits_the_byte_limit_and_keeps_the_newest(repo, monkeypatch):
    for i in range(30):
        commit(repo, f"fix: change number {i:02d} with some length to it")
    git(repo, "tag", "v1.1.0")
    mod = load()
    monkeypatch.setattr(mod, "MAX_BODY_BYTES", 1000)
    _, text, count = mod.build("v1.1.0", "", PREFIX, "o/mono", "o/oss")
    assert len(text.encode()) <= 1000
    listed = entries(text)
    assert listed[-1] == "* fix: change number 29 with some length to it"
    assert f"{30 - len(listed)} earlier changes are not listed." in text
    assert count == len(listed) < 30


def test_body_limit_counts_bytes_not_characters(repo, monkeypatch):
    for i in range(20):
        commit(repo, f"fix: {i:02d} " + "é" * 40)
    git(repo, "tag", "v1.1.0")
    mod = load()
    monkeypatch.setattr(mod, "MAX_BODY_BYTES", 1000)
    _, text, _ = mod.build("v1.1.0", "", PREFIX, "o/mono", "o/oss")
    assert len(text.encode()) <= 1000
    assert "earlier changes are not listed" in text


def test_body_under_the_limit_lists_everything(repo):
    for i in range(5):
        commit(repo, f"fix: {i}")
    git(repo, "tag", "v1.1.0")
    text = body()
    assert len(entries(text)) == 5
    assert "not listed" not in text


def test_the_limit_is_githubs():
    assert load().MAX_BODY_BYTES <= 125_000


# main

def test_main_writes_the_notes_file(repo, env):
    commit(repo, "fix: oss (#1)")
    commit(repo, "feat: pro (#2)", "pro.txt")
    git(repo, "tag", "v1.1.0")
    load().main()
    out = outputs(env)
    assert out["previous-tag"] == "v1.0.0"
    assert out["count"] == "1"
    assert set(out) == {"previous-tag", "notes-file", "count"}
    text = Path(out["notes-file"]).read_text()
    assert text.startswith("## Changelog\n")
    assert entries(text) == ["* fix: oss"]


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


# rendering untrusted subjects

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
    mod.without_refs(subject, mod.ref_patterns())
    assert time.monotonic() - start < 1


@pytest.mark.parametrize("subject", [
    "fix(snapshot): use t.Context() instead of background context",
    "fix: call Close() on the response body",
])
def test_ordinary_parentheses_stay(repo, subject):
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert entries(body()) == [f"* {subject}"]


@pytest.mark.parametrize("subject", [
    "fix x gh-13", "Gh-14 y", "x-#12", "x.#12", "_#12_", "fix x (#12/#13)",
    "_o/mono#12_", "github.com/o/mono/pull/12", "github.com/o/mono#12",
    "GitHub.com/o/mono/pull/3", "ftp://github.com/o/mono/pull/1",
    "https://github.com/o/./mono/pull/12", "o/mono/pull/12", "o/mono/issues/4",
    "o/mono/commit/6d15355ec", "repo@1234567abc", "see https://example.com/x",
    "x/y#5", "www.example.com", "@octocat", "thanks _@octocat_",
    "&#x40;octocat", "<div>&#64octocat</div>",
])
def test_subjects_link_nothing(repo, subject):
    """Whatever stripping leaves sits in a code span, where GitHub links,
    mentions and formats nothing."""
    commit(repo, f"fix: {subject}")
    git(repo, "tag", "v1.1.0")
    match = SPAN.match(raw_entries(body())[0])
    assert match and match.group(3) is None
    assert entries(body())[0].startswith("* fix:")


def test_imported_subjects_mention_nobody(repo):
    commit(repo, f"fix: thanks @someone (#4084)\n\nOss-Commit: {OSS_SHA}\n")
    git(repo, "tag", "v1.1.0")
    assert raw_entries(body())[0].startswith("* `fix: thanks @someone` ([")


def test_a_huge_subject_is_capped_and_fast(repo):
    commit(repo, "fix: " + "www." * 32000)
    git(repo, "tag", "v1.1.0")
    start = time.monotonic()
    text = body()
    assert time.monotonic() - start < 2
    line = entries(text)[0]
    assert len(line) <= 302 and line.endswith("…")


@pytest.mark.parametrize("subject", [
    "fix: use `foo` here", "`leading tick", "trailing tick`", "a ``` b", "``",
    "fix: [click](https://evil.example.com) <img src=x.png> &#x40;octocat",
])
def test_subjects_round_trip_through_a_code_span(repo, subject):
    """Whatever a subject holds, it renders as the same literal text."""
    commit(repo, subject)
    git(repo, "tag", "v1.1.0")
    assert SPAN.match(raw_entries(body())[0])
    assert entries(body()) == [f"* {subject}"]


@pytest.mark.parametrize("separator", ["\r", "\r\r", "\x0b", "\x0c", "\x85", " ", " ", "\x1d"])
def test_a_subject_is_one_line(repo, separator):
    """CommonMark ends a line at a bare CR, which would close the code span
    and let the rest of a replayed subject render as markdown."""
    subject = f"fix a{separator}@octocat [x](https://evil.example) <img src=x>{separator}# Heading"
    commit(repo, subject.encode())
    git(repo, "tag", "v1.1.0")
    text = body()
    assert not re.search(r"[\r\x0b\x0c\x85  \x1c-\x1f]", text)
    raw = raw_entries(text)
    assert len(raw) == 1 and SPAN.match(raw[0])


@pytest.mark.parametrize("run", [4, 79, 80, 200])
def test_long_backtick_runs_keep_the_fence_short(repo, run):
    """GitHub stops matching a code span fence of about 80 backticks."""
    commit(repo, "fix " + "`" * run + " @octocat")
    git(repo, "tag", "v1.1.0")
    match = SPAN.match(raw_entries(body())[0])
    assert match and len(match.group(1)) <= 4
    assert entries(body()) == ["* fix ``` @octocat"]


@pytest.mark.parametrize("control", ["‮", "‪", "⁦", "⁩", "‎", "‏", "؜"])
def test_bidi_controls_cannot_reorder_the_link(repo, control):
    """An unclosed override flows out of the subject and shows the commit
    link after it reversed."""
    commit(repo, f"fix: bump client-go {control}\n\nOss-Commit: {OSS_SHA}\n")
    git(repo, "tag", "v1.1.0")
    assert not re.search("[؜‎‏‪-‮⁦-⁩]", body())

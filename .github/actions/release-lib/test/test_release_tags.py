"""release_tags.py against real throwaway git repos: which tags are stable,
and which earlier tag a release is compared against."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import release_tags  # noqa: E402


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def commit(repo: Path, subject: str) -> str:
    git(repo, "commit", "--allow-empty", "-q", "-m", subject)
    return git(repo, "rev-parse", "HEAD")


def history(tmp_path, monkeypatch, *tags_per_commit):
    """One empty commit per argument, oldest first, each tagged with the tags
    given. Tags on one commit are how a release shares a commit with its rc."""
    r = tmp_path / "history"
    r.mkdir()
    git(r, "init", "-q", "-b", "main")
    git(r, "config", "user.email", "t@example.com")
    git(r, "config", "user.name", "t")
    for i, tags in enumerate(tags_per_commit):
        commit(r, f"commit {i}")
        for tag in tags:
            git(r, "tag", tag)
    monkeypatch.chdir(r)
    return r


def resolve(version: str, override: str = "") -> str:
    return release_tags.resolve_previous_tag(version, override)


def count(prev: str, version: str) -> int:
    return int(release_tags.git("rev-list", "--first-parent", "--count", f"{prev}..{version}"))


@pytest.mark.parametrize("tag, stable", [
    ("v0.34.4", True),
    ("v0.28.2-patch.1", True),
    ("v0.28.2-patch", True),
    ("v0.34.4+build.1", True),
    ("v0.35.0-rc.9", False),
    ("v0.35.0-alpha.8", False),
    ("v0.35.0-beta.2", False),
    ("v0.35.0-dev.1", False),
    ("v0.35.0-pre.1", False),
    ("v0.35.0-next.0", False),
    ("v0.35.0-patchset.1", False),
    ("latest", False),
])
def test_is_stable_matches_linear_release_sync(tag, stable):
    """The cases of linear-release-sync's TestReleaseIsStable."""
    assert release_tags.is_stable(tag) is stable


def test_semver_key_orders_by_precedence():
    ordered = ["v1.2.0-1", "v1.2.0-alpha", "v1.2.0-alpha.1", "v1.2.0-alpha.2",
               "v1.2.0-beta.1", "v1.2.0-rc.2", "v1.2.0-rc.9", "v1.2.0-rc.10",
               "v1.2.0", "v1.2.1", "v1.10.0", "v2.0.0-alpha.1", "v2.0.0"]
    assert sorted(ordered[5:] + ordered[:5], key=release_tags.semver_key) == ordered


@pytest.mark.parametrize("tag", ["v1.2", "v1.2.x", "vnext", "latest", "v1.2.3.4"])
def test_semver_key_rejects_what_is_not_semver(tag):
    assert release_tags.semver_key(tag) is None


def test_previous_tag_skips_next_tags(tmp_path, monkeypatch):
    history(tmp_path, monkeypatch, ["v1.0.0"], ["v1.1.0-next.1"], ["v1.1.0-alpha.1"],
            [], [], ["v1.1.0-alpha.2"])
    assert resolve("v1.1.0-alpha.2") == "v1.1.0-alpha.1"
    assert resolve("v1.1.0-alpha.1") == "v1.0.0"


def test_previous_tag_override(tmp_path, monkeypatch):
    history(tmp_path, monkeypatch, ["v1.0.0"], ["v1.1.0-alpha.1"], ["v1.1.0-alpha.2"])
    assert resolve("v1.1.0-alpha.2", "v1.0.0") == "v1.0.0"


def test_missing_override_raises(tmp_path, monkeypatch):
    history(tmp_path, monkeypatch, ["v1.0.0"], ["v1.1.0-alpha.1"])
    with pytest.raises(release_tags.NoPreviousTag, match="'v9.9.9' is not in the checkout"):
        resolve("v1.1.0-alpha.1", "v9.9.9")


@pytest.mark.parametrize("tags, version", [
    ([["v1.0.0"]], "v1.0.0"),
    ([["v1.0.0-alpha.1"]], "v1.0.0-alpha.1"),
    ([["v1.0.0-alpha.1"], ["v1.0.0-rc.1", "v1.0.0"]], "v1.0.0"),
])
def test_first_of_its_kind_raises(tmp_path, monkeypatch, tags, version):
    """A first release has no earlier tag; a first stable has only
    pre-releases below it."""
    history(tmp_path, monkeypatch, *tags)
    with pytest.raises(release_tags.NoPreviousTag, match="nothing to compare"):
        resolve(version)


def test_stable_skips_the_rc_on_the_same_commit(tmp_path, monkeypatch):
    """v4.12.2 is cut from the commit of v4.12.2-rc.7. Comparing with that rc
    gives an empty range, so a stable tag compares with the previous stable
    and covers every rc in between."""
    history(tmp_path, monkeypatch, ["v4.12.1"], ["v4.12.2-rc.6"],
            ["v4.12.2-rc.7", "v4.12.2"])
    assert resolve("v4.12.2") == "v4.12.1"
    assert count("v4.12.1", "v4.12.2") == 2


def test_override_wins_over_both_rules(tmp_path, monkeypatch):
    history(tmp_path, monkeypatch, ["v4.12.1"], ["v4.12.2-rc.6"],
            ["v4.12.2-rc.7", "v4.12.2"])
    assert resolve("v4.12.2", "v4.12.2-rc.6") == "v4.12.2-rc.6"
    assert resolve("v4.12.2-rc.7", "v4.12.1") == "v4.12.1"


def test_previous_tag_same_commit_orders_numerically(tmp_path, monkeypatch):
    """rc.9 beats beta.1 and alpha.2 below rc.10, whatever the order git
    lists them in; the stable release on the commit compares with the
    previous stable."""
    history(tmp_path, monkeypatch, ["v1.0.0"],
            ["v1.1.0-alpha.2", "v1.1.0-rc.9", "v1.1.0-rc.10", "v1.1.0-beta.1", "v1.1.0"])
    assert resolve("v1.1.0-rc.10") == "v1.1.0-rc.9"
    assert resolve("v1.1.0") == "v1.0.0"


def test_previous_tag_same_commit_ignores_next_tags(tmp_path, monkeypatch):
    """-next sorts between alpha and rc, so only the exclusion keeps it out."""
    history(tmp_path, monkeypatch, ["v1.0.0"],
            ["v1.1.0-alpha.1", "v1.1.0-next.3", "v1.1.0-rc.1"])
    assert resolve("v1.1.0-rc.1") == "v1.1.0-alpha.1"


def test_stable_finds_the_previous_stable_on_a_sibling_branch(tmp_path, monkeypatch):
    """v5.0.0 on main follows v4.12.2 on release-4.12, which describe from
    main cannot reach. A higher stable elsewhere never counts, and the
    pre-release rule is unchanged."""
    r = history(tmp_path, monkeypatch, ["v4.12.0"])
    git(r, "checkout", "-q", "-b", "release-4.12")
    for tag in ("v4.12.1", "v4.12.2"):
        commit(r, tag)
        git(r, "tag", tag)
    git(r, "checkout", "-q", "main")
    commit(r, "alpha")
    git(r, "tag", "v5.0.0-alpha.1")
    commit(r, "rc")
    git(r, "tag", "v5.0.0-rc.1")
    git(r, "tag", "v5.0.0")
    assert git(r, "describe", "--tags", "--abbrev=0", "v5.0.0^") == "v5.0.0-alpha.1"
    assert resolve("v5.0.0") == "v4.12.2"
    assert resolve("v4.12.2") == "v4.12.1"
    assert resolve("v5.0.0-alpha.1") == "v4.12.0"
    assert count("v4.12.2", "v5.0.0") == 2


def test_stable_counts_a_patch_as_stable(tmp_path, monkeypatch):
    """v0.28.2-patch.1 is cut on top of v0.28.2 (vcluster-pro), so it
    compares with v0.28.2 and is itself the base for the next patch, though
    semver sorts it below v0.28.2."""
    history(tmp_path, monkeypatch, ["v0.28.1"], ["v0.28.2-rc.1", "v0.28.2"],
            ["v0.28.2-patch.1"], ["v0.28.2-patch.2"], ["v0.28.3-rc.1", "v0.28.3"])
    assert resolve("v0.28.2-patch.1") == "v0.28.2"
    assert resolve("v0.28.2-patch.2") == "v0.28.2-patch.1"
    assert resolve("v0.28.3") == "v0.28.2-patch.2"


def test_previous_tag_ignores_a_higher_tag_on_the_same_commit(tmp_path, monkeypatch):
    """Resolving the rc while the release already sits on its commit must not
    compare the rc with its own release."""
    history(tmp_path, monkeypatch, ["v1.0.0"], ["v1.1.0-rc.1", "v1.1.0"])
    assert resolve("v1.1.0-rc.1") == "v1.0.0"


def test_previous_tag_falls_back_to_describe_without_a_shared_commit(tmp_path, monkeypatch):
    history(tmp_path, monkeypatch, ["v1.1.0-alpha.1"], [], ["v1.1.0-alpha.2"])
    assert resolve("v1.1.0-alpha.2") == "v1.1.0-alpha.1"


def test_previous_tag_prefers_the_release_over_its_rc_on_one_commit(tmp_path, monkeypatch):
    """v4.12.1-rc.1 follows a commit carrying v4.12.0 and v4.12.0-rc.12.
    describe breaks that tie on tagger date, so an rc tagged later wins over
    the release; the tagger dates here pin that."""
    r = history(tmp_path, monkeypatch, ["v4.12.0-rc.11"], [])
    for tag, date in (("v4.12.0", "2026-01-01T00:00:00"),
                      ("v4.12.0-rc.12", "2026-01-02T00:00:00")):
        subprocess.run(["git", "-C", str(r), "tag", "-a", "-m", tag, tag], check=True,
                       capture_output=True, env={**os.environ, "GIT_COMMITTER_DATE": date})
    commit(r, "commit 2")
    git(r, "tag", "v4.12.1-rc.1")
    assert git(r, "describe", "--tags", "--abbrev=0", "v4.12.1-rc.1^") == "v4.12.0-rc.12"
    assert resolve("v4.12.1-rc.1") == "v4.12.0"


def test_a_patch_alpha_cut_from_main_compares_with_the_nearest_tag(tmp_path, monkeypatch):
    """loft-enterprise cut v4.2.4-alpha.0 from main one commit after
    v4.3.0-alpha.12, with the v4.2 line's own tags on its release branch.
    The nearest tag sorts above it and stays the base: the highest reachable
    tag below it would be an rc from before the whole v4.3 line."""
    r = history(tmp_path, monkeypatch, ["v4.2.2-rc.8"])
    git(r, "checkout", "-q", "-b", "release-4.2")
    commit(r, "v4.2.2")
    git(r, "tag", "v4.2.2")
    git(r, "checkout", "-q", "main")
    for i in range(1, 4):
        commit(r, f"alpha {i}")
        git(r, "tag", f"v4.3.0-alpha.{i}")
    commit(r, "patch")
    git(r, "tag", "v4.2.4-alpha.0")
    assert resolve("v4.2.4-alpha.0") == "v4.3.0-alpha.3"
    assert count("v4.3.0-alpha.3", "v4.2.4-alpha.0") == 1


def test_a_non_semver_nearest_tag_is_still_the_base(tmp_path, monkeypatch):
    """A historical tag like v0.5.0rc1 is not semver, so it cannot be ordered
    against the release and stays the base as before."""
    history(tmp_path, monkeypatch, ["v0.4.0"], ["v0.5.0rc1"], ["v0.5.0-rc.2"])
    assert resolve("v0.5.0-rc.2") == "v0.5.0rc1"


def test_own_commit_false_steps_past_a_lower_tag_on_the_same_commit(tmp_path, monkeypatch):
    """rc.1 cut on the commit of an alpha.2 whose build failed: alpha.2 was
    never released, so comparing with it would list nothing."""
    history(tmp_path, monkeypatch, ["v1.0.0"], ["v1.1.0-alpha.1"],
            ["v1.1.0-alpha.2", "v1.1.0-beta.1", "v1.1.0-rc.1"])
    assert release_tags.resolve_previous_tag("v1.1.0-rc.1", "", own_commit=False) == "v1.1.0-alpha.1"
    assert resolve("v1.1.0-rc.1") == "v1.1.0-beta.1"


def test_own_commit_false_steps_past_a_lower_stable_on_the_same_commit(tmp_path, monkeypatch):
    history(tmp_path, monkeypatch, ["v1.2.2"], ["v1.2.3", "v1.2.4"])
    assert release_tags.resolve_previous_tag("v1.2.4", "", own_commit=False) == "v1.2.2"
    assert resolve("v1.2.4") == "v1.2.3"


@pytest.mark.parametrize("tags, version, expected", [
    ([["v1.0.0"], [], ["v1.1.0-alpha.1"]], "v1.1.0-alpha.1", "v1.0.0"),
    ([["v1.0.0"], ["v1.1.0-rc.1", "v1.1.0"]], "v1.1.0-rc.1", "v1.0.0"),
    ([["v1.0.0"], ["v1.1.0-rc.1"], ["v1.1.0"]], "v1.1.0", "v1.0.0"),
])
def test_own_commit_false_changes_nothing_without_a_lower_tag_there(tmp_path, monkeypatch,
                                                                  tags, version, expected):
    history(tmp_path, monkeypatch, *tags)
    assert release_tags.resolve_previous_tag(version, "", own_commit=False) == expected
    assert resolve(version) == expected


def test_own_commit_false_keeps_the_override(tmp_path, monkeypatch):
    history(tmp_path, monkeypatch, ["v1.0.0"], ["v1.1.0-alpha.2", "v1.1.0-rc.1"])
    assert release_tags.resolve_previous_tag(
        "v1.1.0-rc.1", "v1.1.0-alpha.2", own_commit=False) == "v1.1.0-alpha.2"


@pytest.mark.parametrize("version, expected", [("v1.1.0", "v1.0.0"),
                                               ("v1.1.0-rc.1", "v1.0.0")])
def test_a_tag_name_that_is_not_utf8_does_not_stop_resolving(tmp_path, monkeypatch,
                                                            version, expected):
    """The tag sits on the release's own commit, which both paths list, and
    describe from the commit before never returns it."""
    r = history(tmp_path, monkeypatch, ["v1.0.0"])
    commit(r, "next")
    subprocess.run([b"git", b"-C", bytes(r), b"tag", b"v1.0.9-\xff"], check=True)
    git(r, "tag", version)
    assert resolve(version) == expected


def test_a_nearest_tag_that_is_not_utf8_fails_naming_git(tmp_path, monkeypatch):
    r = history(tmp_path, monkeypatch, ["v1.0.0"])
    commit(r, "odd")
    subprocess.run([b"git", b"-C", bytes(r), b"tag", b"v1.0.1-\xff"], check=True)
    commit(r, "next")
    git(r, "tag", "v1.1.0-rc.1")
    with pytest.raises(subprocess.CalledProcessError):
        resolve("v1.1.0-rc.1")


@pytest.mark.parametrize("tags, version, expected", [
    ([["v1.0.0-alpha.1", "v1.0.0-rc.1"]], "v1.0.0-rc.1", "v1.0.0-alpha.1"),
    ([["v1.0.0", "v1.0.1"]], "v1.0.1", "v1.0.0"),
])
def test_own_commit_false_falls_back_to_a_tag_there_when_nothing_else_is_left(
        tmp_path, monkeypatch, tags, version, expected):
    """Comparing with the tag on the same commit beats failing the release."""
    history(tmp_path, monkeypatch, *tags)
    assert release_tags.resolve_previous_tag(version, "", own_commit=False) == expected

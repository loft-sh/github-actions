"""Release tag rules shared by the Python release actions: which tags are
stable, and which earlier tag a release is compared against.

release-summary and release-notes both read a release's changes from the
range these rules pick, so the Slack summary and the GitHub release body
start from the same tag.

Every function runs git in the current directory, which must be a checkout
of the released repository with full history and tags.
"""
from __future__ import annotations

import fnmatch
import re
import subprocess

# Tags that never get a #product-releases banner, so they make a useless
# comparison base. loft-enterprise alone carries 77 -next tags.
TAG_MATCH = "v*"
TAG_EXCLUDE = "*-next*"

SEMVER = re.compile(r"v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?")


class NoPreviousTag(Exception):
    """No tag to compare against. The message names the remedy."""


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True,
                          text=True).stdout.strip()


def tag_exists(tag: str) -> bool:
    return subprocess.run(["git", "rev-parse", "--verify", "-q",
                           f"refs/tags/{tag}"], capture_output=True).returncode == 0


def is_shallow() -> bool:
    return git("rev-parse", "--is-shallow-repository") == "true"


def semver_key(tag: str) -> tuple | None:
    """Sort key in semver precedence order, None for a tag that is not semver.
    A prerelease sorts below its release and rc.10 above rc.9."""
    m = SEMVER.fullmatch(tag)
    if not m:
        return None
    major, minor, patch, pre = m.groups()
    # Numeric identifiers compare as numbers and sort below alphanumeric ones;
    # (kind, number, text) keeps the three tuple positions comparable.
    ids = tuple((0, int(i), "") if i.isdigit() else (1, 0, i)
                for i in pre.split(".")) if pre else ()
    return (int(major), int(minor), int(patch), 0 if pre else 1, ids)


def is_stable(tag: str) -> bool:
    """Stable by tag name, as linear-release-sync's releaseIsStable decides:
    no prerelease part, or the backport marker patch / patch.N.
    A tag that is not semver is not stable."""
    m = SEMVER.fullmatch(tag)
    if not m:
        return False
    pre = m.group(4) or ""
    return pre == "" or pre == "patch" or pre.startswith("patch.")


def stable_key(tag: str) -> tuple:
    """semver_key for a stable tag, except a patch sorts right above the
    release it patches: v0.28.2-patch.1 is cut on top of v0.28.2, where
    semver would put it below."""
    major, minor, patch, _, ids = semver_key(tag)
    return (major, minor, patch, ids)


def previous_stable(version: str) -> str:
    """The highest stable tag below version, on any branch. Pre-releases in
    between are skipped, so a stable release covers everything the line
    shipped since the last stable; that tag can sit on another release
    branch, out of reach of describe."""
    tags = [t for t in git("tag", "--list", TAG_MATCH).splitlines()
            if not fnmatch.fnmatchcase(t, TAG_EXCLUDE) and is_stable(t)]
    limit = stable_key(version)
    below = [(key, t) for t in tags if (key := stable_key(t)) < limit]
    if not below:
        raise NoPreviousTag(
            f"no stable {TAG_MATCH} tag sorts below {version}, so there is "
            "nothing to compare against; pass previous-tag to set one")
    return max(below)[1]


def release_tags_at(tag: str) -> list[str]:
    """TAG_MATCH tags, minus TAG_EXCLUDE, on the commit tag points at."""
    out = git("tag", "--list", TAG_MATCH, "--points-at", f"refs/tags/{tag}^{{commit}}")
    return [t for t in out.splitlines() if not fnmatch.fnmatchcase(t, TAG_EXCLUDE)]


def nearest_below(version: str, tags: list[str]) -> str:
    """The semver-highest of tags that sorts below version, or ''."""
    limit = semver_key(version)
    if limit is None:
        return ""
    below = [(key, t) for t in tags
             if (key := semver_key(t)) is not None and key < limit]
    return max(below)[1] if below else ""


def resolve_previous_tag(version: str, override: str) -> str:
    """The override when given. Else a stable version compares against the
    previous stable tag, and a pre-release against the nearest non -next tag
    before it: tags on version's own commit first, then `describe version^`,
    which steps past all of them."""
    if override:
        if not tag_exists(override):
            raise NoPreviousTag(
                f"previous tag '{override}' is not in the checkout; pass an "
                "existing tag or leave previous-tag empty to derive it")
        return override
    if is_stable(version):
        return previous_stable(version)
    shared = nearest_below(version, release_tags_at(version))
    if shared:
        return shared
    try:
        found = git("describe", "--tags", "--abbrev=0", f"--match={TAG_MATCH}",
                    f"--exclude={TAG_EXCLUDE}", f"{version}^")
    except subprocess.CalledProcessError:
        raise NoPreviousTag(
            f"no earlier {TAG_MATCH} tag is reachable from {version}, so there "
            "is nothing to compare against; pass previous-tag to set one") from None
    # describe picks arbitrarily among tags sharing a commit (v4.12.0 or its
    # v4.12.0-rc.12), so settle that by semver too. A nearest tag that sorts
    # above version stays the base: a patch pre-release cut from main follows
    # the next line's alpha there, and its own line is not reachable.
    return nearest_below(version, release_tags_at(found)) or found

#!/usr/bin/env python3
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


REGISTRY_URL = os.getenv("GHCR_URL", "https://ghcr.io")
API_URL = os.getenv("GITHUB_API_URL", "https://api.github.com")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
IMAGE = re.compile(r"^ghcr\.io/([A-Za-z0-9-]+)/([a-z0-9._/-]+)$")
MANIFEST_TYPES = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)


class Failure(Exception):
    pass


def log(message):
    print(f"delete-previous-head-image: {message}")


def summary(lines):
    path = os.getenv("GITHUB_STEP_SUMMARY", "")
    if path:
        with open(path, "a", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n\n")


def truthy(raw):
    value = raw.strip().lower()
    if value in ("", "false", "no", "0", "off"):
        return False
    if value in ("true", "yes", "1", "on"):
        return True
    raise Failure(f"unrecognised dry-run value '{raw}'")


def referrer_tag(digest):
    # GHCR has no referrers API, so cosign and attestations use the tag fallback.
    return digest.replace(":", "-")


class Registry:
    def __init__(self, owner, name, token):
        self.repo = f"{owner}/{name}"
        scope = urllib.parse.quote(f"repository:{self.repo}:pull")
        request = urllib.request.Request(f"{REGISTRY_URL}/token?scope={scope}")
        if token:
            basic = base64.b64encode(f"token:{token}".encode()).decode()
            request.add_header("Authorization", f"Basic {basic}")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                self.bearer = json.load(response)["token"]
        except urllib.error.HTTPError as error:
            raise Failure(f"registry token request returned {error.code}") from error
        except OSError as error:
            raise Failure(f"registry token request failed: {error}") from error

    def _open(self, path, method="GET"):
        request = urllib.request.Request(
            f"{REGISTRY_URL}/v2/{self.repo}/{path}",
            method=method,
            headers={
                "Authorization": f"Bearer {self.bearer}",
                "Accept": MANIFEST_TYPES,
            },
        )
        try:
            return urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise Failure(f"registry {method} {path} returned {error.code}") from error
        except OSError as error:
            raise Failure(f"registry {method} {path} failed: {error}") from error

    def digest(self, ref):
        response = self._open(f"manifests/{ref}", method="HEAD")
        if response is None:
            return None
        with response:
            return response.headers["Docker-Content-Digest"]

    def manifest(self, ref):
        response = self._open(f"manifests/{ref}")
        if response is None:
            return None, None
        with response:
            return response.headers["Docker-Content-Digest"], json.load(response)

    def tags(self):
        tags, path = [], "tags/list?n=100"
        while path:
            response = self._open(path)
            if response is None:
                return tags
            with response:
                tags += json.load(response).get("tags") or []
                link = response.headers.get("Link", "")
            match = re.match(r'<[^>]*/v2/[^>]*?/(tags/list\?[^>]+)>; rel="next"', link)
            path = match.group(1) if match else None
        return tags


def children(manifest):
    return [entry["digest"] for entry in (manifest or {}).get("manifests", [])]


def image_tree(registry, digest):
    """Every manifest that belongs to one image, mapped to the tags it may carry,
    plus the subject each referrer index and artifact signs.

    Ordered leaves first and the image index last, so a delete that stops halfway
    leaves the index in place and a later run with the same digest finds the rest.
    """
    _, index = registry.manifest(digest)
    if index is None:
        return {}, {}
    subjects = [digest, *children(index)]
    artifacts, referrer_indexes, signs = {}, {}, {}
    for subject in subjects:
        tag = referrer_tag(subject)
        referrers_digest, referrers = registry.manifest(tag)
        if referrers_digest is None:
            continue
        referrer_indexes[referrers_digest] = {tag}
        signs.setdefault(referrers_digest, subject)
        for referrer in children(referrers):
            artifacts.setdefault(referrer, set())
            signs.setdefault(referrer, subject)
    tree = {**artifacts, **referrer_indexes}
    for subject in reversed(subjects):
        tree.setdefault(subject, set())
    return tree, signs


def protected_digests(registry, skip_tags):
    """Digests reachable from any tag that is not being deleted."""
    protected = {}
    for tag in registry.tags():
        if tag in skip_tags:
            continue
        digest, manifest = registry.manifest(tag)
        if digest is None:
            continue
        for reachable in [digest, *children(manifest)]:
            protected.setdefault(reachable, tag)
    return protected


class Packages:
    def __init__(self, owner, name, token):
        package = urllib.parse.quote(name, safe="")
        self.base = f"{API_URL}/orgs/{owner}/packages/container/{package}/versions"
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    def _call(self, url, method="GET"):
        request = urllib.request.Request(url, method=method, headers=self.headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            raise Failure(f"GitHub API {method} {url} returned {error.code}") from error
        except OSError as error:
            raise Failure(f"GitHub API {method} {url} failed: {error}") from error
        return json.loads(body) if body else None

    def versions(self, wanted):
        found, page = {}, 1
        while len(found) < len(wanted):
            batch = self._call(f"{self.base}?per_page=100&page={page}")
            if not batch:
                break
            for version in batch:
                if version["name"] in wanted:
                    tags = set(
                        version.get("metadata", {}).get("container", {}).get("tags", [])
                    )
                    found[version["name"]] = (version["id"], tags)
            page += 1
        return found

    def delete(self, version_id):
        self._call(f"{self.base}/{version_id}", method="DELETE")


def parse_image(raw):
    match = IMAGE.match(raw.strip())
    if not match:
        raise Failure(f"image must look like ghcr.io/<org>/<name>, got '{raw}'")
    return match.group(1), match.group(2)


def check_digest(name, raw):
    value = raw.strip()
    if value and not DIGEST.match(value):
        raise Failure(f"{name} must be a sha256 digest, got '{raw}'")
    return value


def record(owner, name, token, tag):
    digest = Registry(owner, name, token).digest(tag) or ""
    log(f"{tag} points to {digest or 'nothing yet'}")
    output = os.getenv("GITHUB_OUTPUT", "")
    if output:
        with open(output, "a", encoding="utf-8") as out:
            out.write(f"digest={digest}\n")


def delete(owner, name, token, previous, current, dry_run):
    if not previous:
        log("no previous image recorded; nothing to delete")
        return
    if previous == current:
        log("the new image has the same digest as the previous one; nothing to delete")
        return
    registry = Registry(owner, name, token)
    tree, signs = image_tree(registry, previous)
    if not tree:
        log(f"{previous} is already gone; nothing to delete")
        return
    referrer_tags = set().union(*tree.values())
    protected = protected_digests(registry, referrer_tags)
    if previous in protected:
        log(f"{previous} is still tagged {protected[previous]}; nothing to delete")
        return
    # A kept manifest keeps its signatures and attestations too.
    for digest, subject in signs.items():
        if subject in protected:
            protected.setdefault(digest, protected[subject])

    packages = Packages(owner, name, token)
    versions = packages.versions(set(tree))
    # The registry and the packages API are separate reads; trust the stricter one.
    if previous not in versions:
        log(f"{previous} has no package version; nothing to delete")
        return
    if versions[previous][1]:
        tags = ", ".join(sorted(versions[previous][1]))
        log(f"{previous} is still tagged {tags}; nothing to delete")
        return
    plan, kept = [], []
    for digest, allowed in tree.items():
        if digest in protected:
            kept.append(f"{digest}: also part of tag {protected[digest]}")
        elif digest not in versions:
            kept.append(f"{digest}: no package version found")
        elif not versions[digest][1] <= allowed:
            extra = ", ".join(sorted(versions[digest][1] - allowed))
            kept.append(f"{digest}: carries tag {extra}")
        else:
            plan.append((digest, versions[digest][0]))

    verb = "would delete" if dry_run else "deleting"
    lines = [f"### Previous head image {previous}"]
    for digest, version_id in plan:
        log(f"{verb} {digest} (version {version_id})")
        lines.append(f"- {verb} `{digest}` (version {version_id})")
        if not dry_run:
            packages.delete(version_id)
    for reason in kept:
        log(f"keeping {reason}")
        lines.append(f"- keeping {reason}")
    summary(lines)


def main():
    try:
        mode = os.getenv("INPUT_MODE", "").strip()
        owner, name = parse_image(os.getenv("INPUT_IMAGE", ""))
        token = os.getenv("INPUT_TOKEN", "")
        tag = os.getenv("INPUT_TAG", "").strip() or "head"
        if mode == "record":
            record(owner, name, token, tag)
        elif mode == "delete":
            previous = check_digest(
                "previous-digest", os.getenv("INPUT_PREVIOUS_DIGEST", "")
            )
            current = check_digest(
                "current-digest", os.getenv("INPUT_CURRENT_DIGEST", "")
            )
            if previous and not current:
                raise Failure("current-digest is required when previous-digest is set")
            dry_run = truthy(os.getenv("INPUT_DRY_RUN", ""))
            delete(owner, name, token, previous, current, dry_run)
        else:
            raise Failure(f"mode must be record or delete, got '{mode}'")
    except Failure as error:
        print(f"::error::delete-previous-head-image: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

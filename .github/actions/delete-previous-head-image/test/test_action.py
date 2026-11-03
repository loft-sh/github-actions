import json
import os
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest


ACTION = Path(__file__).parents[1] / "src" / "action.py"
IMAGE = "ghcr.io/loft-sh/vcluster-candy"
INDEX = "application/vnd.oci.image.index.v1+json"


def d(char):
    return "sha256:" + char * 64


def index(*digests):
    return {"mediaType": INDEX, "manifests": [{"digest": x} for x in digests]}


def image():
    return {"mediaType": "application/vnd.oci.image.manifest.v1+json", "layers": []}


class Fake:
    """GHCR registry plus the GitHub packages API, in one server."""

    def __init__(
        self,
        manifests,
        tags,
        versions,
        tag_page=100,
        delete_status=204,
        fail_from=None,
        registry_tags=None,
    ):
        self.manifests = manifests
        self.tags = tags
        # What the registry tag list shows, when it lags the packages API.
        self.registry_tags = registry_tags
        self.versions = versions
        self.deleted = []
        self.calls = []
        self.fail_from = fail_from
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send_json(self, body, headers=None):
                data = json.dumps(body).encode()
                self.send_response(200)
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(data)

            def manifest(self):
                ref = self.path.rsplit("/", 1)[1]
                digest = fake.tags.get(ref, ref)
                if digest not in fake.manifests:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_json(
                    fake.manifests[digest], {"Docker-Content-Digest": digest}
                )

            def do_HEAD(self):
                fake.calls.append(("HEAD", self.path))
                self.manifest()

            def do_GET(self):
                fake.calls.append(("GET", self.path))
                if self.path.startswith("/token"):
                    self.send_json({"token": "registry-token"})
                elif "/manifests/" in self.path:
                    self.manifest()
                elif "/tags/list" in self.path:
                    names = list(
                        fake.tags if fake.registry_tags is None else fake.registry_tags
                    )
                    last = re.search(r"last=([^&]+)", self.path)
                    start = names.index(last.group(1)) + 1 if last else 0
                    page = names[start : start + tag_page]
                    headers = {}
                    if start + tag_page < len(names):
                        headers["Link"] = (
                            f'</v2/loft-sh/vcluster-candy/tags/list?last={page[-1]}&n={tag_page}>; rel="next"'
                        )
                    self.send_json({"tags": page}, headers)
                elif "/versions" in self.path:
                    page = int(re.search(r"[?&]page=(\d+)", self.path).group(1))
                    self.send_json(fake.versions[(page - 1) * 100 : page * 100])
                else:
                    self.send_response(404)
                    self.end_headers()

            def do_DELETE(self):
                fake.calls.append(("DELETE", self.path))
                failing = (
                    fake.fail_from is not None and len(fake.deleted) >= fake.fail_from
                )
                status = 500 if failing else delete_status
                self.send_response(status)
                self.end_headers()
                if status != 204:
                    return
                version_id = int(self.path.rsplit("/", 1)[1])
                fake.deleted.append(version_id)
                digest = next(v["name"] for v in fake.versions if v["id"] == version_id)
                fake.versions[:] = [v for v in fake.versions if v["id"] != version_id]
                fake.manifests.pop(digest, None)
                for tag in [t for t, x in fake.tags.items() if x == digest]:
                    del fake.tags[tag]

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


def version(id_, digest, *tags):
    return {"id": id_, "name": digest, "metadata": {"container": {"tags": list(tags)}}}


def run(fake, tmp_path, **inputs):
    output = tmp_path / "output"
    env = {
        "PATH": os.environ["PATH"],
        "GHCR_URL": fake.url,
        "GITHUB_API_URL": fake.url,
        "GITHUB_OUTPUT": str(output),
        "GITHUB_STEP_SUMMARY": str(tmp_path / "summary"),
        "INPUT_IMAGE": IMAGE,
        "INPUT_TOKEN": "gh-token",
    }
    env.update({f"INPUT_{key.upper()}": value for key, value in inputs.items()})
    result = subprocess.run(
        ["python3", str(ACTION)], env=env, capture_output=True, text=True
    )
    result.output = output.read_text() if output.exists() else ""
    return result


def candy():
    """head moved from OLD to NEW; v1 is a release. Each image is signed."""
    old, new, rel = d("a"), d("b"), d("c")
    manifests = {
        old: index(d("1"), d("2")),
        d("1"): image(),
        d("2"): image(),
        d("e"): index(d("3")),  # referrers of OLD (cosign bundle)
        d("3"): image(),
        new: index(d("4")),
        d("4"): image(),
        rel: index(d("5"), d("6")),
        d("5"): image(),
        d("6"): image(),
        d("f"): index(d("7")),  # referrers of the release
        d("7"): image(),
    }
    tags = {
        "v1": rel,
        "sha256-" + rel[7:]: d("f"),
        "head": new,
        "sha256-" + old[7:]: d("e"),
    }
    versions = [
        version(1, old),
        version(2, d("1")),
        version(3, d("2")),
        version(4, d("e"), "sha256-" + old[7:]),
        version(5, d("3")),
        version(6, new, "head"),
        version(7, d("4")),
        version(8, rel, "v1"),
        version(9, d("5")),
        version(10, d("6")),
        version(11, d("f"), "sha256-" + rel[7:]),
        version(12, d("7")),
    ]
    return old, new, manifests, tags, versions


@pytest.fixture
def fake():
    servers = []

    def make(**kwargs):
        old, new, manifests, tags, versions = candy()
        server = Fake(
            kwargs.pop("manifests", manifests),
            kwargs.pop("tags", tags),
            versions,
            **kwargs,
        )
        servers.append(server)
        server.old, server.new = old, new
        return server

    yield make
    for server in servers:
        server.close()


def test_record_writes_the_digest_the_tag_points_to(fake, tmp_path):
    server = fake()
    result = run(server, tmp_path, mode="record")
    assert result.returncode == 0, result.stdout
    assert result.output == f"digest={server.new}\n"


def test_record_writes_empty_digest_when_the_tag_does_not_exist(fake, tmp_path):
    server = fake()
    result = run(server, tmp_path, mode="record", tag="missing")
    assert result.returncode == 0, result.stdout
    assert result.output == "digest=\n"


def test_delete_removes_only_the_previous_image_and_its_referrers(fake, tmp_path):
    server = fake()
    result = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.old,
        current_digest=server.new,
    )
    assert result.returncode == 0, result.stdout
    assert sorted(server.deleted) == [1, 2, 3, 4, 5]
    assert "deleting" in (tmp_path / "summary").read_text()


def test_dry_run_deletes_nothing(fake, tmp_path):
    server = fake()
    result = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.old,
        current_digest=server.new,
        dry_run="true",
    )
    assert result.returncode == 0, result.stdout
    assert server.deleted == []
    assert not [call for call in server.calls if call[0] == "DELETE"]
    assert result.stdout.count("would delete") == 5


def test_manifest_shared_with_a_tagged_image_is_kept(fake, tmp_path):
    old, new, manifests, tags, versions = candy()
    manifests[old] = index(d("1"), d("5"))  # d("5") also belongs to the release
    server = fake(manifests=manifests)
    result = run(
        server, tmp_path, mode="delete", previous_digest=old, current_digest=new
    )
    assert result.returncode == 0, result.stdout
    assert 9 not in server.deleted
    assert sorted(server.deleted) == [1, 2, 4, 5]
    assert "also part of tag v1" in result.stdout


def test_previous_image_that_is_still_tagged_is_kept(fake, tmp_path):
    old, new, manifests, tags, versions = candy()
    tags["v2"] = old  # someone promoted the old head to a release
    server = fake(tags=tags)
    result = run(
        server, tmp_path, mode="delete", previous_digest=old, current_digest=new
    )
    assert result.returncode == 0, result.stdout
    assert server.deleted == []
    assert "still tagged v2" in result.stdout


def test_version_with_an_unexpected_tag_is_kept(fake, tmp_path):
    server = fake()
    server.versions[1] = version(2, d("1"), "debug")
    result = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.old,
        current_digest=server.new,
    )
    assert result.returncode == 0, result.stdout
    assert 2 not in server.deleted
    assert "carries tag debug" in result.stdout


def test_no_previous_digest_is_a_no_op(fake, tmp_path):
    server = fake()
    result = run(
        server, tmp_path, mode="delete", previous_digest="", current_digest=server.new
    )
    assert result.returncode == 0, result.stdout
    assert server.calls == []


def test_unchanged_digest_is_a_no_op(fake, tmp_path):
    server = fake()
    result = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.new,
        current_digest=server.new,
    )
    assert result.returncode == 0, result.stdout
    assert server.calls == []


def test_tag_list_is_paginated(fake, tmp_path):
    server = fake(tag_page=1)
    result = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.old,
        current_digest=server.new,
    )
    assert result.returncode == 0, result.stdout
    assert sorted(server.deleted) == [1, 2, 3, 4, 5]


def test_leaves_are_deleted_before_the_image_index(fake, tmp_path):
    server = fake()
    result = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.old,
        current_digest=server.new,
    )
    assert result.returncode == 0, result.stdout
    # signature, its referrer index, platform manifests, then the index itself
    assert server.deleted == [5, 4, 3, 2, 1]


def test_tag_seen_only_by_the_packages_api_keeps_everything(fake, tmp_path):
    old, new, manifests, tags, versions = candy()
    registry_tags = list(tags)  # the registry snapshot has not seen v2 yet
    tags["v2"] = old
    server = fake(tags=tags, registry_tags=registry_tags)
    server.versions[0] = version(1, old, "v2")
    result = run(
        server, tmp_path, mode="delete", previous_digest=old, current_digest=new
    )
    assert result.returncode == 0, result.stdout
    assert server.deleted == []
    assert "still tagged v2" in result.stdout


def test_rerun_after_a_partial_delete_finishes_the_cleanup(fake, tmp_path):
    server = fake(fail_from=2)
    first = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.old,
        current_digest=server.new,
    )
    assert first.returncode == 1
    assert server.deleted == [5, 4]
    server.fail_from = None
    second = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.old,
        current_digest=server.new,
    )
    assert second.returncode == 0, second.stdout
    assert server.deleted == [5, 4, 3, 2, 1]


def test_failed_delete_fails_the_step(fake, tmp_path):
    server = fake(delete_status=403)
    result = run(
        server,
        tmp_path,
        mode="delete",
        previous_digest=server.old,
        current_digest=server.new,
    )
    assert result.returncode == 1
    assert "returned 403" in result.stdout


@pytest.mark.parametrize(
    "inputs, message",
    [
        (
            {"mode": "delete", "previous_digest": "latest", "current_digest": d("b")},
            "must be a sha256 digest",
        ),
        (
            {"mode": "delete", "previous_digest": d("a"), "current_digest": ""},
            "current-digest is required",
        ),
        (
            {
                "mode": "delete",
                "previous_digest": d("a"),
                "current_digest": d("b"),
                "dry_run": "maybe",
            },
            "unrecognised dry-run",
        ),
        ({"mode": "prune"}, "mode must be record or delete"),
        ({"mode": "record", "image": "docker.io/loft-sh/x"}, "image must look like"),
    ],
)
def test_bad_inputs_fail_before_any_request(fake, tmp_path, inputs, message):
    server = fake()
    result = run(server, tmp_path, **inputs)
    assert result.returncode == 1
    assert message in result.stdout
    assert server.calls == []

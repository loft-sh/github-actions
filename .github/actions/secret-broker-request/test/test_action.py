import base64
import copy
import json
import os
import subprocess
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ACTION = Path(__file__).parents[1] / "src" / "action.py"
ACTION_METADATA = Path(__file__).parents[1] / "action.yml"


def timestamp(value):
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


@pytest.fixture(scope="session")
def request_fixture(tmp_path_factory):
    work = tmp_path_factory.mktemp("secret-broker-request")
    now = datetime.now(timezone.utc).replace(microsecond=0)
    request_id = f"{int(now.timestamp())}-0123456789abcdef01234567"
    private_key = work / "private.pem"
    certificate = work / "public.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:3072",
            "-sha256",
            "-days",
            "1",
            "-nodes",
            "-subj",
            f"/CN=secret-broker-request-{request_id}",
            "-keyout",
            str(private_key),
            "-out",
            str(certificate),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    request = {
        "request_version": 1,
        "request_id": request_id,
        "requested_secret_alias": "test-secret",
        "ephemeral_public_key": certificate.read_text(),
        "created_at": timestamp(now),
        "expires_at": timestamp(now + timedelta(minutes=5)),
        "nonce": "abcdef0123456789abcdef0123456789",
    }
    return request


class ApiServer:
    def __init__(self, request, membership=None, user=None, failures=None):
        self.request = request
        self.membership = (
            membership
            if membership is not None
            else {"state": "active", "role": "member"}
        )
        self.user = user if user is not None else {"login": "requester", "id": 123456}
        self.failures = failures or {}
        self.calls = []

        parent = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                parent.calls.append(("GET", self.path, None))
                status = parent.failures.get(self.path, 200)
                if "/contents/" in self.path:
                    payload = {
                        "type": "file",
                        "encoding": "base64",
                        "content": base64.b64encode(
                            (json.dumps(parent.request, sort_keys=True) + "\n").encode()
                        ).decode(),
                    }
                elif self.path.startswith("/users/"):
                    payload = parent.user
                elif "/memberships/" in self.path:
                    payload = parent.membership
                else:
                    status = 404
                    payload = {"message": "not found"}
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length))
                parent.calls.append(("POST", self.path, payload))
                status = parent.failures.get(self.path, 201)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"ref": payload.get("ref")}).encode())

            def log_message(self, _format, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True
        )

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def workflow_run(request, **changes):
    event = {
        "id": 12345,
        "run_attempt": 1,
        "event": "push",
        "conclusion": "success",
        "head_repository": {
            "full_name": "example-org/secret-broker-consumer",
        },
        "head_sha": "a" * 40,
        "head_branch": f"secret-broker-request/{request['request_id']}",
        "actor": {"login": "requester", "id": 123456},
    }
    event.update(changes)
    return event


def run_action(tmp_path, server, request, workflow_run_changes=None, **changes):
    output = tmp_path / "github-output"
    runner_temp = tmp_path / "runner-temp"
    request_file = runner_temp / "secret-broker" / "request.json"
    public_key_file = runner_temp / "secret-broker" / "public.pem"
    env = {
        **os.environ,
        "GITHUB_OUTPUT": str(output),
        "GITHUB_REPOSITORY": "example-org/secret-broker-consumer",
        "GITHUB_RUN_ID": "67890",
        "GITHUB_RUN_ATTEMPT": "1",
        "GITHUB_SHA": "b" * 40,
        "GITHUB_WORKFLOW_REF": (
            "example-org/secret-broker-consumer/"
            ".github/workflows/broker.yaml@refs/heads/main"
        ),
        "GITHUB_TOKEN": "repository-token",
        "GITHUB_API_URL": server.url,
        "RUNNER_TEMP": str(runner_temp),
        "SECRET_BROKER_WORKFLOW_RUN": json.dumps(
            workflow_run(request, **(workflow_run_changes or {}))
        ),
        "INPUT_ORGANIZATION": "example-org",
        "INPUT_ALLOWED_SECRET_ALIASES": "test-secret\nteam/secondary",
        "SECRET_BROKER_AUTH_TOKEN": "installation-token",
        "INPUT_AUTHORIZATION": "",
        **changes,
    }
    result = subprocess.run(
        ["python3", str(ACTION)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    outputs = {}
    if output.exists():
        for line in output.read_text().splitlines():
            key, _, value = line.partition("=")
            outputs[key] = value
    return result, outputs, request_file, public_key_file


def test_authorize_accepts_active_org_member_without_team_check(
    tmp_path, request_fixture
):
    with ApiServer(request_fixture) as server:
        result, outputs, _, _ = run_action(tmp_path, server, request_fixture)

    assert result.returncode == 0, result.stderr
    authorization = json.loads(outputs["authorization"])
    assert authorization["source"]["head_branch"].endswith(
        request_fixture["request_id"]
    )
    assert authorization["authorization"]["secret_alias"] == "test-secret"
    assert authorization["source"]["actor_login"] == "requester"
    assert authorization["source"]["actor_id"] == 123456
    assert server.calls[0] == (
        "GET",
        "/repos/example-org/secret-broker-consumer/contents/"
        ".secret-broker-request.json?ref=" + "a" * 40,
        None,
    )
    assert authorization["authorization"]["organization"] == "example-org"
    assert (
        "GET",
        "/orgs/example-org/memberships/requester",
        None,
    ) in server.calls
    assert not any("/teams/" in call[1] for call in server.calls)


def test_authorize_exposes_one_opaque_handoff(tmp_path, request_fixture):
    with ApiServer(request_fixture) as server:
        result, outputs, _, _ = run_action(tmp_path, server, request_fixture)

    assert result.returncode == 0, result.stderr
    assert set(outputs) == {"authorization"}
    authorization = json.loads(outputs["authorization"])
    assert authorization["request_sha256"]
    assert authorization["source"]["head_branch"].endswith(
        request_fixture["request_id"]
    )
    assert authorization["source"]["actor_login"] == "requester"
    assert authorization["source"]["actor_id"] == 123456


def test_action_metadata_keeps_the_public_contract_small():
    metadata = ACTION_METADATA.read_text()

    def names(section):
        lines = metadata.splitlines()
        start = lines.index(f"{section}:") + 1
        result = []
        for line in lines[start:]:
            if line and not line.startswith(" "):
                break
            if line.startswith("  ") and not line.startswith("    "):
                result.append(line.strip().removesuffix(":"))
        return result

    assert names("inputs") == [
        "app-client-id",
        "app-private-key",
        "organization",
        "allowed-secret-aliases",
        "authorization",
    ]
    assert names("outputs") == ["authorization", "bundle"]


@pytest.mark.parametrize(
    ("membership", "failures", "message"),
    [
        ({"state": "pending", "role": "member"}, {}, "not active"),
        (
            {},
            {"/orgs/example-org/memberships/requester": 404},
            "not a member",
        ),
        (
            {},
            {"/orgs/example-org/memberships/requester": 403},
            "check failed",
        ),
        (
            {},
            {"/orgs/example-org/memberships/requester": 500},
            "check failed",
        ),
    ],
)
def test_authorize_fails_closed_on_org_membership_errors(
    tmp_path, request_fixture, membership, failures, message
):
    with ApiServer(request_fixture, membership=membership, failures=failures) as server:
        result, _, _, _ = run_action(tmp_path, server, request_fixture)

    assert result.returncode != 0
    assert message in result.stderr


def test_authorize_rejects_actor_id_mismatch(tmp_path, request_fixture):
    with ApiServer(request_fixture, user={"login": "requester", "id": 999}) as server:
        result, _, _, _ = run_action(tmp_path, server, request_fixture)

    assert result.returncode != 0
    assert "stable ID" in result.stderr


@pytest.mark.parametrize("attempt", ["2", "9"])
def test_authorize_rejects_source_and_broker_reruns(tmp_path, request_fixture, attempt):
    with ApiServer(request_fixture) as server:
        source, _, _, _ = run_action(
            tmp_path,
            server,
            request_fixture,
            workflow_run_changes={"run_attempt": int(attempt)},
        )
        broker, _, _, _ = run_action(
            tmp_path, server, request_fixture, GITHUB_RUN_ATTEMPT=attempt
        )

    assert source.returncode != 0
    assert broker.returncode != 0
    assert "re-runs" in source.stderr
    assert "re-runs" in broker.stderr


@pytest.mark.parametrize(
    ("change", "message"),
    [
        ({"requested_secret_alias": "op://vault/item/password"}, "not allowed"),
        ({"requested_by": "someone-else"}, "unexpected fields"),
        (
            {
                "created_at": "2020-01-01T00:00:00Z",
                "expires_at": "2020-01-01T00:05:00Z",
            },
            "expired",
        ),
        (
            {
                "expires_at": timestamp(
                    datetime.now(timezone.utc) + timedelta(minutes=11)
                )
            },
            "validity window",
        ),
        (
            {
                "created_at": timestamp(
                    datetime.now(timezone.utc) + timedelta(minutes=2)
                ),
                "expires_at": timestamp(
                    datetime.now(timezone.utc) + timedelta(minutes=7)
                ),
            },
            "too far in the future",
        ),
    ],
)
def test_authorize_rejects_hostile_or_stale_request(
    tmp_path, request_fixture, change, message
):
    request = copy.deepcopy(request_fixture)
    request.update(change)
    with ApiServer(request) as server:
        result, _, _, _ = run_action(tmp_path, server, request_fixture)

    assert result.returncode != 0
    assert message in result.stderr


def test_preflight_revalidates_and_claims_before_writing_files(
    tmp_path, request_fixture
):
    with ApiServer(request_fixture) as server:
        authorized, outputs, _, _ = run_action(tmp_path, server, request_fixture)
        assert authorized.returncode == 0, authorized.stderr
        result, _, request_file, public_key_file = run_action(
            tmp_path,
            server,
            request_fixture,
            INPUT_AUTHORIZATION=outputs["authorization"],
        )

    assert result.returncode == 0, result.stderr
    assert json.loads(request_file.read_text()) == request_fixture
    assert "BEGIN CERTIFICATE" in public_key_file.read_text()
    bundle = request_file.parent
    authorization_file = bundle / "authorization.json"
    assert json.loads(authorization_file.read_text()) == json.loads(
        outputs["authorization"]
    )
    assert bundle.stat().st_mode & 0o777 == 0o700
    assert request_file.stat().st_mode & 0o777 == 0o600
    assert public_key_file.stat().st_mode & 0o777 == 0o600
    assert authorization_file.stat().st_mode & 0o777 == 0o600
    claim = [call for call in server.calls if call[0] == "POST"]
    assert claim == [
        (
            "POST",
            "/repos/example-org/secret-broker-consumer/git/refs",
            {
                "ref": (
                    "refs/tags/secret-broker-processed/"
                    + json.loads(outputs["authorization"])["request_sha256"]
                ),
                "sha": "b" * 40,
            },
        )
    ]


def test_preflight_rejects_duplicate_claim(tmp_path, request_fixture):
    path = "/repos/example-org/secret-broker-consumer/git/refs"
    with ApiServer(request_fixture, failures={path: 422}) as server:
        authorized, outputs, _, _ = run_action(tmp_path, server, request_fixture)
        assert authorized.returncode == 0, authorized.stderr
        result, _, request_file, _ = run_action(
            tmp_path,
            server,
            request_fixture,
            INPUT_AUTHORIZATION=outputs["authorization"],
        )

    assert result.returncode != 0
    assert "already processed" in result.stderr
    assert not request_file.exists()


def test_preflight_rejects_request_changed_after_authorization(
    tmp_path, request_fixture
):
    with ApiServer(copy.deepcopy(request_fixture)) as server:
        authorized, outputs, _, _ = run_action(tmp_path, server, request_fixture)
        assert authorized.returncode == 0, authorized.stderr
        server.request["requested_secret_alias"] = "team/secondary"
        result, _, request_file, public_key_file = run_action(
            tmp_path,
            server,
            request_fixture,
            INPUT_AUTHORIZATION=outputs["authorization"],
        )

    assert result.returncode != 0
    assert "request digest does not match" in result.stderr
    assert not request_file.exists()
    assert not public_key_file.exists()
    assert not [call for call in server.calls if call[0] == "POST"]


@pytest.mark.parametrize(
    ("workflow_run_changes", "environment_changes"),
    [
        (
            {
                "head_branch": (
                    "secret-broker-request/1788429600-deadbeefdeadbeefdeadbeef"
                )
            },
            {},
        ),
        ({"head_sha": "c" * 40}, {}),
        ({"id": 54321}, {}),
        ({"actor": {"login": "another-user", "id": 999999}}, {}),
        ({}, {"GITHUB_RUN_ID": "98765"}),
        ({}, {"GITHUB_WORKFLOW_REF": "example-org/other/.github/workflows/x@main"}),
        ({}, {"GITHUB_SHA": "c" * 40}),
    ],
)
def test_preflight_rejects_changed_workflow_context(
    tmp_path, request_fixture, workflow_run_changes, environment_changes
):
    with ApiServer(request_fixture) as server:
        authorized, outputs, _, _ = run_action(tmp_path, server, request_fixture)
        assert authorized.returncode == 0, authorized.stderr
        result, _, request_file, _ = run_action(
            tmp_path,
            server,
            request_fixture,
            workflow_run_changes=workflow_run_changes,
            INPUT_AUTHORIZATION=outputs["authorization"],
            **environment_changes,
        )

    assert result.returncode != 0
    assert "workflow run changed" in result.stderr
    assert not request_file.exists()


@pytest.mark.parametrize("field", ["GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"])
def test_rejects_invalid_broker_run_numbers(tmp_path, request_fixture, field):
    with ApiServer(request_fixture) as server:
        result, _, _, _ = run_action(
            tmp_path, server, request_fixture, **{field: "not-a-number"}
        )

    assert result.returncode != 0
    assert f"{field} must be a positive integer" in result.stderr


@pytest.mark.parametrize("rerun", ["source", "broker"])
def test_preflight_rejects_reruns(tmp_path, request_fixture, rerun):
    with ApiServer(request_fixture) as server:
        authorized, outputs, _, _ = run_action(tmp_path, server, request_fixture)
        assert authorized.returncode == 0, authorized.stderr
        result, _, request_file, public_key_file = run_action(
            tmp_path,
            server,
            request_fixture,
            workflow_run_changes={"run_attempt": 2} if rerun == "source" else None,
            INPUT_AUTHORIZATION=outputs["authorization"],
            **({"GITHUB_RUN_ATTEMPT": "2"} if rerun == "broker" else {}),
        )

    assert result.returncode != 0
    assert "re-runs" in result.stderr
    assert not request_file.exists()
    assert not public_key_file.exists()
    assert not [call for call in server.calls if call[0] == "POST"]

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import NamedTuple

REQUEST_FIELDS = {
    "request_version",
    "request_id",
    "requested_secret_alias",
    "ephemeral_public_key",
    "created_at",
    "expires_at",
    "nonce",
}
MAX_REQUEST_BYTES = 32768
MAX_REQUEST_VALIDITY_SECONDS = 600
MAX_FUTURE_SKEW_SECONDS = 60
REQUEST_ID_RE = re.compile(r"^([0-9]{10})-([a-f0-9]{24})$")
NONCE_RE = re.compile(r"^[a-f0-9]{32}$")
SHA_RE = re.compile(r"^[a-f0-9]{40}$")
LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
ALIAS_RE = re.compile(r"^[a-z0-9](?:[a-z0-9._/-]{0,126}[a-z0-9])?$")
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
REQUEST_BRANCH_PREFIX = "secret-broker-request/"
REQUEST_PATH = ".secret-broker-request.json"
PROCESSED_REF_PREFIX = "refs/tags/secret-broker-processed/"


class BrokerError(Exception):
    pass


class ApiError(BrokerError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class ValidatedRequest(NamedTuple):
    request_id: str
    requested_secret_alias: str
    ephemeral_public_key: str
    public_key_fingerprint: str
    created_at: str
    expires_at: str
    nonce: str


class WorkflowRun(NamedTuple):
    repository: str
    commit: str
    branch: str
    request_id: str
    actor: str
    actor_id: int
    source_run_id: int
    source_run_attempt: int


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise BrokerError(f"{name} is required")
    return value


def positive_int(name):
    value = required(name)
    if not value.isdigit() or int(value) <= 0:
        raise BrokerError(f"{name} must be a positive integer")
    return int(value)


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0)


def parse_timestamp(value, field):
    if not isinstance(value, str):
        raise BrokerError(f"{field} must be a string")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise BrokerError(f"{field} must use UTC RFC3339 seconds") from error


def serialize_json(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def compact_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def load_request(raw):
    if len(raw) > MAX_REQUEST_BYTES:
        raise BrokerError("request is too large")

    def reject_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise BrokerError(f"request contains duplicate field {key}")
            result[key] = value
        return result

    try:
        request = json.loads(raw, object_pairs_hook=reject_duplicates)
    except UnicodeDecodeError as error:
        raise BrokerError("request is not UTF-8") from error
    except json.JSONDecodeError as error:
        raise BrokerError("request is not valid JSON") from error
    if not isinstance(request, dict):
        raise BrokerError("request must be a JSON object")
    return request


def openssl(arguments, input_bytes=None):
    try:
        return subprocess.run(
            ["openssl", *arguments],
            input=input_bytes,
            check=True,
            capture_output=True,
        ).stdout
    except FileNotFoundError as error:
        raise BrokerError("openssl is not on PATH") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        raise BrokerError(f"ephemeral public key is invalid: {detail}") from error


def validate_public_key(certificate, request_id, seconds_remaining):
    if not isinstance(certificate, str):
        raise BrokerError("ephemeral_public_key must be a string")
    encoded = certificate.encode()
    if not 500 <= len(encoded) <= 16384:
        raise BrokerError("ephemeral public key has an invalid size")
    if "PRIVATE KEY" in certificate:
        raise BrokerError("request contains private key material")
    pem = re.compile(
        r"-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+"
        r"-----END CERTIFICATE-----\n?\Z"
    )
    if pem.fullmatch(certificate) is None:
        raise BrokerError(
            "ephemeral public key must contain exactly one PEM certificate"
        )

    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
        handle.write(certificate)
        handle.flush()
        openssl(
            ["x509", "-in", handle.name, "-noout", "-checkend", str(seconds_remaining)]
        )
        subject = (
            openssl(
                [
                    "x509",
                    "-in",
                    handle.name,
                    "-noout",
                    "-subject",
                    "-nameopt",
                    "RFC2253",
                ]
            )
            .decode()
            .strip()
        )
        details = openssl(["x509", "-in", handle.name, "-noout", "-text"]).decode()
        public_pem = openssl(["x509", "-in", handle.name, "-pubkey", "-noout"])

    if subject != f"subject=CN=secret-broker-request-{request_id}":
        raise BrokerError("ephemeral public key subject does not match request_id")
    if "Public Key Algorithm: rsaEncryption" not in details:
        raise BrokerError("ephemeral public key must use RSA")
    key_size = re.search(r"Public-Key: \(([0-9]+) bit\)", details)
    if key_size is None or int(key_size.group(1)) < 3072:
        raise BrokerError("ephemeral public key must use at least 3072 bits")

    public_der = openssl(["pkey", "-pubin", "-outform", "DER"], input_bytes=public_pem)
    return "sha256:" + hashlib.sha256(public_der).hexdigest()


def allowed_aliases():
    raw = required("INPUT_ALLOWED_SECRET_ALIASES")
    aliases = {part.strip() for line in raw.splitlines() for part in line.split(",")}
    aliases.discard("")
    if not aliases or any(ALIAS_RE.fullmatch(alias) is None for alias in aliases):
        raise BrokerError("allowed secret aliases are invalid")
    return aliases


def validate_request(request, request_id, aliases, now=None):
    now = now or utc_now()
    missing = sorted(REQUEST_FIELDS - set(request))
    unexpected = sorted(set(request) - REQUEST_FIELDS)
    if missing:
        raise BrokerError(f"request is missing fields: {', '.join(missing)}")
    if unexpected:
        raise BrokerError(f"request has unexpected fields: {', '.join(unexpected)}")
    if type(request["request_version"]) is not int or request["request_version"] != 1:
        raise BrokerError("request_version must be 1")
    if (
        not isinstance(request["request_id"], str)
        or REQUEST_ID_RE.fullmatch(request["request_id"]) is None
    ):
        raise BrokerError("request_id is invalid")
    if request["request_id"] != request_id:
        raise BrokerError("request_id does not match the request branch")
    alias = request["requested_secret_alias"]
    if not isinstance(alias, str) or alias not in aliases:
        raise BrokerError("requested secret alias is not allowed")
    nonce = request["nonce"]
    if not isinstance(nonce, str) or NONCE_RE.fullmatch(nonce) is None:
        raise BrokerError("nonce is invalid")

    created = parse_timestamp(request["created_at"], "created_at")
    expires = parse_timestamp(request["expires_at"], "expires_at")
    if created > now + timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
        raise BrokerError("request timestamp is too far in the future")
    if expires <= now:
        raise BrokerError("request is expired")
    validity = (expires - created).total_seconds()
    if validity <= 0 or validity > MAX_REQUEST_VALIDITY_SECONDS:
        raise BrokerError("request validity window is invalid")
    request_epoch = int(REQUEST_ID_RE.fullmatch(request_id).group(1))
    if abs(request_epoch - int(created.timestamp())) > MAX_FUTURE_SKEW_SECONDS:
        raise BrokerError("request_id timestamp does not match created_at")

    seconds_remaining = max(1, int((expires - now).total_seconds()))
    fingerprint = validate_public_key(
        request["ephemeral_public_key"], request_id, seconds_remaining
    )
    return ValidatedRequest(
        request_id=request_id,
        requested_secret_alias=alias,
        ephemeral_public_key=request["ephemeral_public_key"],
        public_key_fingerprint=fingerprint,
        created_at=request["created_at"],
        expires_at=request["expires_at"],
        nonce=nonce,
    )


def validate_api_url(value):
    parsed = urllib.parse.urlparse(value)
    loopback_test = parsed.scheme == "http" and parsed.hostname in {
        "127.0.0.1",
        "localhost",
    }
    if parsed.scheme != "https" and not loopback_test:
        raise BrokerError("github-api-url must use HTTPS")
    if not parsed.netloc or parsed.params or parsed.query or parsed.fragment:
        raise BrokerError("github-api-url is invalid")
    return value.rstrip("/")


def api_json(method, url, token, payload=None):
    data = None if payload is None else serialize_json(payload)
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2026-03-10",
            "User-Agent": "secret-broker-request-action",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read(1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        raise ApiError(error.code, f"GitHub API returned HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise ApiError(0, f"GitHub API request failed: {error.reason}") from error
    if len(raw) > 1024 * 1024:
        raise ApiError(0, "GitHub API response is too large")
    try:
        return json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ApiError(0, "GitHub API returned invalid JSON") from error


def load_workflow_run():
    try:
        workflow_run = json.loads(required("SECRET_BROKER_WORKFLOW_RUN"))
    except json.JSONDecodeError as error:
        raise BrokerError("workflow_run event is not valid JSON") from error
    if not isinstance(workflow_run, dict):
        raise BrokerError("workflow_run event is invalid")

    repository = required("GITHUB_REPOSITORY")
    if REPOSITORY_RE.fullmatch(repository) is None:
        raise BrokerError("request repository is invalid")
    source_repository = workflow_run.get("head_repository")
    actor = workflow_run.get("actor")
    if not isinstance(source_repository, dict) or not isinstance(actor, dict):
        raise BrokerError("workflow_run event is invalid")
    if source_repository.get("full_name") != repository:
        raise BrokerError("request must originate in the broker repository")
    if (
        workflow_run.get("event") != "push"
        or workflow_run.get("conclusion") != "success"
    ):
        raise BrokerError("source workflow run is not a successful push")

    commit = workflow_run.get("head_sha")
    branch = workflow_run.get("head_branch")
    if not isinstance(commit, str) or SHA_RE.fullmatch(commit) is None:
        raise BrokerError("request commit is invalid")
    if not isinstance(branch, str) or not branch.startswith(REQUEST_BRANCH_PREFIX):
        raise BrokerError("request branch is invalid")
    request_id = branch[len(REQUEST_BRANCH_PREFIX) :]
    if REQUEST_ID_RE.fullmatch(request_id) is None:
        raise BrokerError("request branch is invalid")

    actor_login = actor.get("login")
    actor_id = actor.get("id")
    source_run_id = workflow_run.get("id")
    source_run_attempt = workflow_run.get("run_attempt")
    if not isinstance(actor_login, str) or LOGIN_RE.fullmatch(actor_login) is None:
        raise BrokerError("GitHub actor is invalid")
    if type(actor_id) is not int or actor_id <= 0:
        raise BrokerError("GitHub actor ID is invalid")
    if type(source_run_id) is not int or source_run_id <= 0:
        raise BrokerError("source workflow run ID is invalid")
    if type(source_run_attempt) is not int or source_run_attempt != 1:
        raise BrokerError("workflow re-runs cannot issue secrets")
    if positive_int("GITHUB_RUN_ATTEMPT") != 1:
        raise BrokerError("workflow re-runs cannot issue secrets")

    return WorkflowRun(
        repository=repository,
        commit=commit,
        branch=branch,
        request_id=request_id,
        actor=actor_login,
        actor_id=actor_id,
        source_run_id=source_run_id,
        source_run_attempt=source_run_attempt,
    )


def fetch_request(repository, commit, token, api_url):
    path = urllib.parse.quote(REQUEST_PATH, safe="")
    query = urllib.parse.urlencode({"ref": commit})
    url = f"{api_url}/repos/{repository}/contents/{path}?{query}"
    try:
        response = api_json("GET", url, token)
        if response.get("type") != "file" or response.get("encoding") != "base64":
            raise KeyError("unexpected content response")
        encoded = response["content"].replace("\n", "")
        raw = base64.b64decode(encoded, validate=True)
    except ApiError as error:
        raise BrokerError(f"could not fetch request: {error}") from error
    except (AttributeError, KeyError, TypeError, ValueError) as error:
        raise BrokerError("GitHub returned an invalid request file response") from error
    if len(raw) > MAX_REQUEST_BYTES:
        raise BrokerError("request is too large")
    return raw


def authorize_organization_member(api_url, auth_token, actor, actor_id):
    organization = required("INPUT_ORGANIZATION")
    if LOGIN_RE.fullmatch(organization) is None:
        raise BrokerError("authorization organization is invalid")

    user_url = f"{api_url}/users/{urllib.parse.quote(actor, safe='')}"
    try:
        user = api_json("GET", user_url, auth_token)
    except ApiError as error:
        raise BrokerError(f"GitHub actor identity check failed: {error}") from error
    if not isinstance(user, dict) or user.get("id") != actor_id:
        raise BrokerError(
            f"GitHub actor {actor} no longer matches stable ID {actor_id}"
        )

    membership_url = (
        f"{api_url}/orgs/{urllib.parse.quote(organization, safe='')}/memberships/"
        f"{urllib.parse.quote(actor, safe='')}"
    )
    try:
        membership = api_json("GET", membership_url, auth_token)
    except ApiError as error:
        if error.status == 404:
            raise BrokerError(
                f"GitHub actor {actor} is not a member of {organization}"
            ) from error
        raise BrokerError(
            f"organization membership check failed: {error}"
        ) from error
    if not isinstance(membership, dict) or membership.get("state") != "active":
        raise BrokerError(
            f"GitHub actor {actor} has organization membership that is not active"
        )
    return organization, membership.get("role", "unknown")


def write_outputs(values):
    path = Path(required("GITHUB_OUTPUT"))
    with path.open("a", encoding="utf-8") as handle:
        for name, value in values.items():
            if "\n" in str(value) or "\r" in str(value):
                raise BrokerError(f"output {name} contains a newline")
            handle.write(f"{name}={value}\n")


def authorize_request():
    workflow_run = load_workflow_run()
    api_url = validate_api_url(required("GITHUB_API_URL"))
    raw = fetch_request(
        workflow_run.repository,
        workflow_run.commit,
        required("GITHUB_TOKEN"),
        api_url,
    )
    request = validate_request(
        load_request(raw), workflow_run.request_id, allowed_aliases()
    )
    organization, role = authorize_organization_member(
        api_url,
        required("SECRET_BROKER_AUTH_TOKEN"),
        workflow_run.actor,
        workflow_run.actor_id,
    )
    authorization = {
        "version": 1,
        "broker": {
            "repository": workflow_run.repository,
            "run_id": positive_int("GITHUB_RUN_ID"),
            "run_attempt": positive_int("GITHUB_RUN_ATTEMPT"),
            "workflow_ref": required("GITHUB_WORKFLOW_REF"),
            "sha": required("GITHUB_SHA"),
        },
        "source": {
            "repository": workflow_run.repository,
            "run_id": workflow_run.source_run_id,
            "run_attempt": workflow_run.source_run_attempt,
            "head_sha": workflow_run.commit,
            "head_branch": workflow_run.branch,
            "actor_login": workflow_run.actor,
            "actor_id": workflow_run.actor_id,
        },
        "authorization": {
            "organization": organization,
            "secret_alias": request.requested_secret_alias,
        },
        "request_sha256": hashlib.sha256(raw).hexdigest(),
    }
    write_outputs({"authorization": compact_json(authorization)})
    print(
        "authorized request "
        + json.dumps(
            {
                "actor": workflow_run.actor,
                "actor_id": workflow_run.actor_id,
                "request_id": workflow_run.request_id,
                "secret_alias": request.requested_secret_alias,
                "organization": organization,
                "membership_role": role,
            },
            sort_keys=True,
        )
    )


def load_authorization():
    raw = required("INPUT_AUTHORIZATION")
    if len(raw.encode()) > 8192:
        raise BrokerError("authorization is too large")

    def reject_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise BrokerError(f"authorization contains duplicate field {key}")
            result[key] = value
        return result

    try:
        authorization = json.loads(raw, object_pairs_hook=reject_duplicates)
    except json.JSONDecodeError as error:
        raise BrokerError("authorization is not valid JSON") from error
    if not isinstance(authorization, dict) or set(authorization) != {
        "version",
        "broker",
        "source",
        "authorization",
        "request_sha256",
    }:
        raise BrokerError("authorization is invalid")
    broker = authorization.get("broker")
    source = authorization.get("source")
    policy = authorization.get("authorization")
    if (
        type(authorization.get("version")) is not int
        or authorization["version"] != 1
        or not isinstance(broker, dict)
        or not isinstance(source, dict)
        or not isinstance(policy, dict)
        or set(broker)
        != {
            "repository",
            "run_id",
            "run_attempt",
            "workflow_ref",
            "sha",
        }
        or set(source)
        != {
            "repository",
            "run_id",
            "run_attempt",
            "head_sha",
            "head_branch",
            "actor_login",
            "actor_id",
        }
        or set(policy) != {"organization", "secret_alias"}
    ):
        raise BrokerError("authorization is invalid")
    if (
        not isinstance(broker["repository"], str)
        or REPOSITORY_RE.fullmatch(broker["repository"]) is None
        or type(broker["run_id"]) is not int
        or broker["run_id"] <= 0
        or type(broker["run_attempt"]) is not int
        or broker["run_attempt"] != 1
        or not isinstance(broker["workflow_ref"], str)
        or not 1 <= len(broker["workflow_ref"]) <= 512
        or not isinstance(broker["sha"], str)
        or SHA_RE.fullmatch(broker["sha"]) is None
        or not isinstance(source["repository"], str)
        or REPOSITORY_RE.fullmatch(source["repository"]) is None
        or type(source["run_id"]) is not int
        or source["run_id"] <= 0
        or type(source["run_attempt"]) is not int
        or source["run_attempt"] != 1
        or not isinstance(source["head_sha"], str)
        or SHA_RE.fullmatch(source["head_sha"]) is None
        or not isinstance(source["head_branch"], str)
        or not source["head_branch"].startswith(REQUEST_BRANCH_PREFIX)
        or REQUEST_ID_RE.fullmatch(source["head_branch"][len(REQUEST_BRANCH_PREFIX) :])
        is None
        or not isinstance(source["actor_login"], str)
        or LOGIN_RE.fullmatch(source["actor_login"]) is None
        or type(source["actor_id"]) is not int
        or source["actor_id"] <= 0
        or not isinstance(policy["organization"], str)
        or LOGIN_RE.fullmatch(policy["organization"]) is None
        or not isinstance(policy["secret_alias"], str)
        or ALIAS_RE.fullmatch(policy["secret_alias"]) is None
        or not isinstance(authorization["request_sha256"], str)
        or SHA256_RE.fullmatch(authorization["request_sha256"]) is None
    ):
        raise BrokerError("authorization is invalid")
    return authorization


def validate_workflow_binding(authorization, workflow_run):
    broker = authorization["broker"]
    source = authorization["source"]
    expected = (
        broker["repository"],
        broker["run_id"],
        broker["run_attempt"],
        broker["workflow_ref"],
        broker["sha"],
        source["repository"],
        source["head_sha"],
        source["head_branch"],
        source["actor_login"],
        source["actor_id"],
        source["run_id"],
        source["run_attempt"],
    )
    actual = (
        required("GITHUB_REPOSITORY"),
        positive_int("GITHUB_RUN_ID"),
        positive_int("GITHUB_RUN_ATTEMPT"),
        required("GITHUB_WORKFLOW_REF"),
        required("GITHUB_SHA"),
        workflow_run.repository,
        workflow_run.commit,
        workflow_run.branch,
        workflow_run.actor,
        workflow_run.actor_id,
        workflow_run.source_run_id,
        workflow_run.source_run_attempt,
    )
    if actual != expected:
        raise BrokerError("workflow run changed after authorization")


def validate_authorized_request(raw, authorization):
    policy = authorization["authorization"]
    if hashlib.sha256(raw).hexdigest() != authorization["request_sha256"]:
        raise BrokerError("authorized request digest does not match")
    validated = validate_request(
        load_request(raw),
        authorization["source"]["head_branch"][len(REQUEST_BRANCH_PREFIX) :],
        {policy["secret_alias"]},
    )
    return validated


def claim(api_url, repository, claim_key):
    trusted_commit = required("GITHUB_SHA")
    if SHA_RE.fullmatch(trusted_commit) is None:
        raise BrokerError("trusted commit is invalid")
    url = f"{api_url}/repos/{repository}/git/refs"
    payload = {"ref": PROCESSED_REF_PREFIX + claim_key, "sha": trusted_commit}
    try:
        api_json("POST", url, required("GITHUB_TOKEN"), payload)
    except ApiError as error:
        if error.status == 422:
            raise BrokerError("request was already processed") from error
        raise BrokerError(f"could not claim request: {error}") from error


def write_private_file(path, content, binary=False):
    output = Path(path)
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if binary:
        output.write_bytes(content)
    else:
        output.write_text(content)
    output.chmod(0o600)


def preflight_request():
    workflow_run = load_workflow_run()
    authorization = load_authorization()
    validate_workflow_binding(authorization, workflow_run)
    api_url = validate_api_url(required("GITHUB_API_URL"))
    raw = fetch_request(
        workflow_run.repository,
        workflow_run.commit,
        required("GITHUB_TOKEN"),
        api_url,
    )
    request = validate_authorized_request(raw, authorization)
    claim(api_url, workflow_run.repository, authorization["request_sha256"])

    bundle = Path(required("RUNNER_TEMP")) / "secret-broker"
    bundle.mkdir(mode=0o700, parents=True, exist_ok=True)
    bundle.chmod(0o700)
    write_private_file(bundle / "request.json", raw, binary=True)
    write_private_file(bundle / "public.pem", request.ephemeral_public_key)
    write_private_file(
        bundle / "authorization.json", compact_json(authorization) + "\n"
    )
    write_outputs({"bundle": str(bundle)})
    print(f"claimed request {workflow_run.request_id} for one issuance")


def main():
    try:
        if os.environ.get("INPUT_AUTHORIZATION", ""):
            preflight_request()
        else:
            authorize_request()
    except BrokerError as error:
        print(f"secret broker: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

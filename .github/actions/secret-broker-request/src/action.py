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
SLUG_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?$")
ALIAS_RE = re.compile(r"^[a-z0-9](?:[a-z0-9._/-]{0,126}[a-z0-9])?$")


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


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise BrokerError(f"{name} is required")
    return value


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


def repository_and_request_id():
    repository = required("INPUT_REQUEST_REPOSITORY")
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is None:
        raise BrokerError("request repository is invalid")
    commit = required("INPUT_REQUEST_COMMIT")
    if SHA_RE.fullmatch(commit) is None:
        raise BrokerError("request commit is invalid")
    prefix = required("INPUT_REQUEST_BRANCH_PREFIX")
    branch = required("INPUT_REQUEST_BRANCH")
    if not branch.startswith(prefix):
        raise BrokerError("request branch prefix does not match")
    request_id = branch[len(prefix) :]
    if REQUEST_ID_RE.fullmatch(request_id) is None:
        raise BrokerError("request branch is invalid")
    return repository, commit, request_id


def fetch_request(repository, commit, token, api_url):
    path = urllib.parse.quote(required("INPUT_REQUEST_PATH"), safe="")
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


def validate_run_attempts():
    if (
        required("INPUT_SOURCE_RUN_ATTEMPT") != "1"
        or required("INPUT_BROKER_RUN_ATTEMPT") != "1"
    ):
        raise BrokerError("workflow re-runs cannot issue secrets")


def validate_actor_inputs():
    actor = required("INPUT_ACTOR")
    actor_id = required("INPUT_ACTOR_ID")
    source_run_id = required("INPUT_SOURCE_RUN_ID")
    if LOGIN_RE.fullmatch(actor) is None:
        raise BrokerError("GitHub actor is invalid")
    if not actor_id.isdigit() or int(actor_id) <= 0:
        raise BrokerError("GitHub actor ID is invalid")
    if not source_run_id.isdigit() or int(source_run_id) <= 0:
        raise BrokerError("source workflow run ID is invalid")
    validate_run_attempts()
    return actor, actor_id, source_run_id


def authorize(api_url, auth_token, actor, actor_id):
    org = required("INPUT_AUTHORIZATION_ORG")
    team = required("INPUT_AUTHORIZATION_TEAM")
    if LOGIN_RE.fullmatch(org) is None or SLUG_RE.fullmatch(team) is None:
        raise BrokerError("authorization organization or team is invalid")

    user_url = f"{api_url}/users/{urllib.parse.quote(actor, safe='')}"
    try:
        user = api_json("GET", user_url, auth_token)
    except ApiError as error:
        raise BrokerError(f"GitHub actor identity check failed: {error}") from error
    if not isinstance(user, dict) or str(user.get("id", "")) != actor_id:
        raise BrokerError(
            f"GitHub actor {actor} no longer matches stable ID {actor_id}"
        )

    membership_url = (
        f"{api_url}/orgs/{urllib.parse.quote(org, safe='')}/teams/"
        f"{urllib.parse.quote(team, safe='')}/memberships/"
        f"{urllib.parse.quote(actor, safe='')}"
    )
    try:
        membership = api_json("GET", membership_url, auth_token)
    except ApiError as error:
        if error.status == 404:
            raise BrokerError(
                f"GitHub actor {actor} is not a member of {org}/{team}"
            ) from error
        raise BrokerError(f"team membership check failed: {error}") from error
    if not isinstance(membership, dict) or membership.get("state") != "active":
        raise BrokerError(f"GitHub actor {actor} has membership that is not active")
    return org, team, membership.get("role", "unknown")


def write_outputs(values):
    path = Path(required("GITHUB_OUTPUT"))
    with path.open("a", encoding="utf-8") as handle:
        for name, value in values.items():
            if "\n" in str(value) or "\r" in str(value):
                raise BrokerError(f"output {name} contains a newline")
            handle.write(f"{name}={value}\n")


def authorize_request():
    api_url = validate_api_url(required("INPUT_GITHUB_API_URL"))
    repository, commit, request_id = repository_and_request_id()
    actor, actor_id, source_run_id = validate_actor_inputs()
    raw = fetch_request(repository, commit, required("INPUT_REPOSITORY_TOKEN"), api_url)
    request = validate_request(load_request(raw), request_id, allowed_aliases())
    org, team, role = authorize(
        api_url, required("SECRET_BROKER_AUTH_TOKEN"), actor, actor_id
    )
    outputs = {
        "request-id": request.request_id,
        "requested-secret-alias": request.requested_secret_alias,
        "request-sha256": hashlib.sha256(raw).hexdigest(),
        "public-key-fingerprint": request.public_key_fingerprint,
        "created-at": request.created_at,
        "expires-at": request.expires_at,
        "nonce": request.nonce,
        "actor": actor,
        "actor-id": actor_id,
        "source-run-id": source_run_id,
    }
    write_outputs(outputs)
    print(
        "authorized request "
        + json.dumps(
            {
                **outputs,
                "repository": repository,
                "team": f"{org}/{team}",
                "membership-role": role,
            },
            sort_keys=True,
        )
    )


def validate_expected(raw):
    expected_id = required("INPUT_EXPECTED_REQUEST_ID")
    validated = validate_request(load_request(raw), expected_id, allowed_aliases())
    comparisons = {
        "request digest": (
            hashlib.sha256(raw).hexdigest(),
            required("INPUT_EXPECTED_REQUEST_SHA256"),
        ),
        "public key fingerprint": (
            validated.public_key_fingerprint,
            required("INPUT_EXPECTED_PUBLIC_KEY_FINGERPRINT"),
        ),
        "secret alias": (
            validated.requested_secret_alias,
            required("INPUT_EXPECTED_SECRET_ALIAS"),
        ),
        "created_at": (validated.created_at, required("INPUT_EXPECTED_CREATED_AT")),
        "expires_at": (validated.expires_at, required("INPUT_EXPECTED_EXPIRES_AT")),
        "nonce": (validated.nonce, required("INPUT_EXPECTED_NONCE")),
    }
    for label, (actual, expected) in comparisons.items():
        if actual != expected:
            raise BrokerError(f"authorized request {label} does not match")
    return validated


def claim(api_url, repository, request_id):
    trusted_commit = required("INPUT_TRUSTED_COMMIT")
    if SHA_RE.fullmatch(trusted_commit) is None:
        raise BrokerError("trusted commit is invalid")
    prefix = required("INPUT_PROCESSED_REF_PREFIX")
    if (
        not prefix.startswith("refs/tags/")
        or not prefix.endswith("/")
        or ".." in prefix
        or "//" in prefix
        or re.fullmatch(r"refs/tags/[A-Za-z0-9._/-]+/", prefix) is None
    ):
        raise BrokerError("processed ref prefix is invalid")
    url = f"{api_url}/repos/{repository}/git/refs"
    payload = {"ref": prefix + request_id, "sha": trusted_commit}
    try:
        api_json("POST", url, required("INPUT_REPOSITORY_TOKEN"), payload)
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
    validate_run_attempts()
    api_url = validate_api_url(required("INPUT_GITHUB_API_URL"))
    repository, commit, request_id = repository_and_request_id()
    if request_id != required("INPUT_EXPECTED_REQUEST_ID"):
        raise BrokerError("request branch changed after authorization")
    raw = fetch_request(repository, commit, required("INPUT_REPOSITORY_TOKEN"), api_url)
    request = validate_expected(raw)
    claim(api_url, repository, request_id)
    request_file = required("INPUT_REQUEST_OUTPUT_FILE")
    public_key_file = required("INPUT_PUBLIC_KEY_OUTPUT_FILE")
    write_private_file(request_file, raw, binary=True)
    write_private_file(public_key_file, request.ephemeral_public_key)
    write_outputs({"request-file": request_file, "public-key-file": public_key_file})
    print(f"claimed request {request_id} for one issuance")


def main():
    try:
        operation = required("INPUT_OPERATION")
        if operation == "authorize":
            authorize_request()
        elif operation == "preflight":
            preflight_request()
        else:
            raise BrokerError("operation must be authorize or preflight")
    except BrokerError as error:
        print(f"secret broker: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

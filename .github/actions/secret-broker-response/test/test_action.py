import json
import os
import stat
import subprocess
from pathlib import Path

import pytest


ACTION = Path(__file__).parents[1] / "src" / "action.py"
ACTION_METADATA = Path(__file__).parents[1] / "action.yml"


@pytest.fixture(scope="session")
def certificate(tmp_path_factory):
    work = tmp_path_factory.mktemp("secret-broker-response-certificate")
    private_key = work / "private.pem"
    public_key = work / "public.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-days",
            "1",
            "-nodes",
            "-subj",
            "/CN=secret-broker-response-test",
            "-keyout",
            str(private_key),
            "-out",
            str(public_key),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return private_key, public_key


def install_mock_op(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    op = bin_dir / "op"
    op.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

Path(os.environ["MOCK_OP_CALL"]).write_text(json.dumps({
    "args": sys.argv[1:],
    "token_present": os.environ.get("OP_SERVICE_ACCOUNT_TOKEN") == "service-token",
}))
exit_code = int(os.environ.get("MOCK_OP_EXIT", "0"))
if exit_code:
    print("mock read failed for a sensitive reference", file=sys.stderr)
    raise SystemExit(exit_code)
sys.stdout.buffer.write(Path(os.environ["MOCK_SECRET_FILE"]).read_bytes())
"""
    )
    op.chmod(0o755)
    return bin_dir


def make_bundle(tmp_path, public_key, alias="platform-license"):
    bundle = tmp_path / "bundle"
    bundle.mkdir(mode=0o700)
    (bundle / "authorization.json").write_text(
        json.dumps({"authorization": {"secret_alias": alias}}) + "\n"
    )
    (bundle / "public.pem").write_bytes(public_key.read_bytes())
    return bundle


def run_action(
    tmp_path,
    public_key,
    *,
    secret=b"secret-value",
    references=None,
    alias="platform-license",
    env_changes=None,
):
    bin_dir = install_mock_op(tmp_path)
    bundle = make_bundle(tmp_path, public_key, alias)
    secret_file = tmp_path / "mock-secret"
    secret_file.write_bytes(secret)
    output = tmp_path / "github-output"
    op_call = tmp_path / "op-call.json"
    reference_input = references or {
        "platform-license": "op://Automation/platform-license/license"
    }
    if not isinstance(reference_input, str):
        reference_input = json.dumps(reference_input)
    env = {
        **os.environ,
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "INPUT_BUNDLE": str(bundle),
        "INPUT_SECRET_REFERENCES": reference_input,
        "INPUT_OP_SERVICE_ACCOUNT_TOKEN": "service-token",
        "GITHUB_OUTPUT": str(output),
        "MOCK_SECRET_FILE": str(secret_file),
        "MOCK_OP_CALL": str(op_call),
        **(env_changes or {}),
    }
    result = subprocess.run(
        ["python3", str(ACTION)], env=env, capture_output=True, text=True
    )
    return result, bundle, output, op_call, bin_dir


def ciphertext_path(output):
    prefix = "ciphertext="
    return Path(
        next(line.removeprefix(prefix) for line in output.read_text().splitlines() if line.startswith(prefix))
    )


def test_streams_selected_secret_directly_to_cms(tmp_path, certificate):
    private_key, public_key = certificate
    secret = b"exact secret bytes\nincluding trailing newline\n"
    reference = "op://Automation/platform-license/license"
    result, bundle, output, op_call, _ = run_action(
        tmp_path,
        public_key,
        secret=secret,
        references={"platform-license": reference, "other": "op://Vault/item/field"},
    )

    assert result.returncode == 0, result.stderr
    encrypted = ciphertext_path(output)
    assert encrypted == bundle / "response.der"
    assert stat.S_IMODE(encrypted.stat().st_mode) == 0o600
    decrypted = subprocess.run(
        [
            "openssl",
            "smime",
            "-decrypt",
            "-inform",
            "DER",
            "-in",
            str(encrypted),
            "-inkey",
            str(private_key),
        ],
        check=True,
        capture_output=True,
    ).stdout
    assert decrypted == secret
    assert json.loads(op_call.read_text()) == {
        "args": ["read", "--no-newline", reference],
        "token_present": True,
    }
    assert secret.decode() not in result.stdout + result.stderr
    assert reference not in result.stdout + result.stderr
    assert sorted(path.name for path in bundle.iterdir()) == [
        "authorization.json",
        "public.pem",
        "response.der",
    ]


def test_action_metadata_keeps_plaintext_out_of_github_channels():
    metadata = ACTION_METADATA.read_text()

    assert "GITHUB_ENV" not in metadata
    assert "secret-output" not in metadata
    assert metadata.count("${{ inputs.op-service-account-token }}") == 1
    assert "INPUT_OP_SERVICE_ACCOUNT_TOKEN" in metadata
    assert "team" not in metadata.lower()


@pytest.mark.parametrize(
    "references,error",
    [
        ({"other": "op://Vault/item/field"}, "has no configured secret reference"),
        ({"platform-license": ""}, "must be a non-empty 1Password reference"),
        ({"platform-license": "not-a-reference"}, "must start with op://"),
        ("[]", "must be a JSON object"),
        ('{"platform-license":"op://one","platform-license":"op://two"}', "duplicate alias"),
    ],
)
def test_rejects_invalid_reference_maps_before_secret_access(
    tmp_path, certificate, references, error
):
    _, public_key = certificate
    result, bundle, output, op_call, _ = run_action(
        tmp_path, public_key, references=references
    )

    assert result.returncode == 1
    assert error in result.stderr
    assert not op_call.exists()
    assert not output.exists()
    assert not (bundle / "response.der").exists()


def test_requires_service_account_token_before_secret_access(tmp_path, certificate):
    _, public_key = certificate
    result, bundle, output, op_call, _ = run_action(
        tmp_path,
        public_key,
        env_changes={"INPUT_OP_SERVICE_ACCOUNT_TOKEN": ""},
    )

    assert result.returncode == 1
    assert "op-service-account-token is required" in result.stderr
    assert not op_call.exists()
    assert not output.exists()
    assert not (bundle / "response.der").exists()


def test_removes_partial_ciphertext_when_secret_read_fails(tmp_path, certificate):
    _, public_key = certificate
    result, bundle, output, op_call, _ = run_action(
        tmp_path, public_key, env_changes={"MOCK_OP_EXIT": "7"}
    )

    assert result.returncode == 1
    assert "1Password secret retrieval failed" in result.stderr
    assert "sensitive reference" not in result.stderr
    assert op_call.exists()
    assert not output.exists()
    assert not (bundle / "response.der").exists()
    assert not list(bundle.glob(".response.*"))


def test_removes_partial_ciphertext_when_encryption_fails(tmp_path, certificate):
    _, public_key = certificate
    result, bundle, output, _, bin_dir = run_action(tmp_path, public_key)
    assert result.returncode == 0
    (bundle / "response.der").unlink()
    output.unlink()

    openssl = bin_dir / "openssl"
    openssl.write_text("#!/usr/bin/env bash\ncat >/dev/null\nexit 9\n")
    openssl.chmod(0o755)
    result = subprocess.run(
        ["python3", str(ACTION)],
        env={
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "INPUT_BUNDLE": str(bundle),
            "INPUT_SECRET_REFERENCES": json.dumps(
                {"platform-license": "op://Automation/platform-license/license"}
            ),
            "INPUT_OP_SERVICE_ACCOUNT_TOKEN": "service-token",
            "GITHUB_OUTPUT": str(output),
            "MOCK_SECRET_FILE": str(tmp_path / "mock-secret"),
            "MOCK_OP_CALL": str(tmp_path / "op-call-2.json"),
        },
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert "CMS encryption failed" in result.stderr
    assert not output.exists()
    assert not (bundle / "response.der").exists()
    assert not list(bundle.glob(".response.*"))

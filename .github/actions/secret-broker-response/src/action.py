#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


class BrokerError(Exception):
    pass


def required(name):
    value = os.environ.get(name, "")
    if not value:
        input_name = name.removeprefix("INPUT_").lower().replace("_", "-")
        raise BrokerError(f"{input_name} is required")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise BrokerError(f"secret-references contains duplicate alias {key!r}")
        result[key] = value
    return result


def load_json(path, description):
    try:
        return json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BrokerError(f"{description} is invalid") from exc


def load_alias(bundle):
    authorization = load_json(bundle / "authorization.json", "authorization bundle")
    try:
        alias = authorization["authorization"]["secret_alias"]
    except (KeyError, TypeError) as exc:
        raise BrokerError("authorization bundle has no secret alias") from exc
    if not isinstance(alias, str) or not alias:
        raise BrokerError("authorization bundle has an invalid secret alias")
    return alias


def load_references(raw):
    try:
        references = json.loads(raw, object_pairs_hook=unique_object)
    except BrokerError:
        raise
    except json.JSONDecodeError as exc:
        raise BrokerError("secret-references is not valid JSON") from exc
    if not isinstance(references, dict):
        raise BrokerError("secret-references must be a JSON object")
    for alias, reference in references.items():
        if not isinstance(alias, str) or not alias:
            raise BrokerError("secret-references contains an invalid alias")
        if not isinstance(reference, str) or not reference:
            raise BrokerError(
                f"secret reference for alias {alias!r} must be a non-empty 1Password reference"
            )
        if not reference.startswith("op://"):
            raise BrokerError(f"secret reference for alias {alias!r} must start with op://")
    return references


def encrypt(bundle, reference, token):
    certificate = bundle / "public.pem"
    if not certificate.is_file():
        raise BrokerError("broker bundle has no public certificate")

    ciphertext = bundle / "response.der"
    ciphertext.unlink(missing_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=bundle, prefix=".response.", suffix=".der"
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    temporary.chmod(0o600)

    child_env = os.environ.copy()
    child_env.pop("INPUT_OP_SERVICE_ACCOUNT_TOKEN", None)
    child_env["OP_SERVICE_ACCOUNT_TOKEN"] = token
    op_process = None
    try:
        op_process = subprocess.Popen(
            ["op", "read", "--no-newline", reference],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=child_env,
        )
        try:
            openssl_process = subprocess.Popen(
                [
                    "openssl",
                    "smime",
                    "-encrypt",
                    "-binary",
                    "-aes-256-cbc",
                    "-outform",
                    "DER",
                    "-in",
                    "/dev/stdin",
                    "-out",
                    str(temporary),
                    str(certificate),
                ],
                stdin=op_process.stdout,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            op_process.kill()
            op_process.wait()
            raise
        assert op_process.stdout is not None
        op_process.stdout.close()
        openssl_status = openssl_process.wait()
        op_status = op_process.wait()
        if op_status != 0:
            raise BrokerError("1Password secret retrieval failed")
        if openssl_status != 0:
            raise BrokerError("CMS encryption failed")
        if temporary.stat().st_size == 0:
            raise BrokerError("CMS encryption produced no ciphertext")
        temporary.replace(ciphertext)
        ciphertext.chmod(0o600)
        return ciphertext
    except FileNotFoundError as exc:
        raise BrokerError(f"required command is unavailable: {exc.filename}") from exc
    finally:
        if op_process is not None and op_process.poll() is None:
            op_process.kill()
            op_process.wait()
        temporary.unlink(missing_ok=True)


def write_output(name, value):
    output = Path(required("GITHUB_OUTPUT"))
    with output.open("a") as stream:
        stream.write(f"{name}={value}\n")


def run():
    bundle = Path(required("INPUT_BUNDLE"))
    if not bundle.is_dir():
        raise BrokerError("bundle is not a directory")
    alias = load_alias(bundle)
    references = load_references(required("INPUT_SECRET_REFERENCES"))
    if alias not in references:
        raise BrokerError(f"approved alias {alias!r} has no configured secret reference")
    token = required("INPUT_OP_SERVICE_ACCOUNT_TOKEN")
    ciphertext = encrypt(bundle, references[alias], token)
    write_output("ciphertext", ciphertext)
    print(f"encrypted approved secret alias {alias!r}")


def main():
    try:
        run()
    except BrokerError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()

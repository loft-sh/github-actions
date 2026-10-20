"""Run a fixed offline zizmor policy without loading code from the scanned repo."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import venv

VERSION = "1.30.1"
POLICY = Path(__file__).resolve().parents[1] / "policy.yml"


class CheckError(Exception):
    """A tool, input, or output error that must fail the check."""


def run(command, **kwargs):
    return subprocess.run(command, check=False, capture_output=True, text=True, **kwargs)


def scanner(directory):
    """Use the exact installed version, or install into a disposable venv."""
    existing = shutil.which("zizmor")
    if existing:
        result = run([existing, "--version"])
        if result.returncode == 0 and result.stdout.strip() == f"zizmor {VERSION}":
            return existing
    environment = Path(directory) / "venv"
    venv.create(environment, with_pip=True)
    result = run([
        str(environment / "bin/python"), "-I", "-m", "pip", "--isolated",
        "install", "--index-url", "https://pypi.org/simple", "--only-binary=:all:",
        "--no-deps", f"zizmor=={VERSION}",
    ])
    if result.returncode:
        raise CheckError(f"Could not install zizmor {VERSION}: {result.stderr}")
    return str(environment / "bin/zizmor")


def findings(output):
    try:
        records = json.loads(output)
    except (TypeError, json.JSONDecodeError) as error:
        raise CheckError("zizmor returned invalid JSON") from error
    if not isinstance(records, list):
        raise CheckError("zizmor returned an unexpected findings schema")
    pins = []
    for record in records:
        if (not isinstance(record, dict)
                or not isinstance(record.get("ident"), str)
                or not isinstance(record.get("desc"), str)
                or not isinstance(record.get("locations"), list)
                or not record["locations"]
                or not isinstance(record.get("ignored"), bool)):
            raise CheckError("zizmor returned an invalid finding")
        if record["ident"] == "unpinned-uses":
            pins.append(record)
    return pins


def check(binary, repository):
    target = Path(repository).resolve() / ".github"
    if not target.is_dir():
        raise CheckError(f"Missing scan directory: {target}")
    # Do not let the caller's zizmor settings alter the action-owned policy.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("ZIZMOR_")}
    result = run([
        binary, "--offline", "--no-progress", "--format", "json",
        "--no-exit-codes", "--no-ignores", "--strict-collection",
        "--collect", "all", "--config", str(POLICY), str(target),
    ], env=environment)
    if result.returncode:
        raise CheckError(f"zizmor failed ({result.returncode}): {result.stderr}")
    pins = findings(result.stdout)
    for finding in pins:
        # Plain text avoids interpreting scanned content as workflow commands.
        print(json.dumps({"rule": finding["ident"], "message": finding["desc"],
                          "locations": finding["locations"]}, ensure_ascii=True))
    print(f"Action pin check: {len(pins)} pinning finding(s).")
    return 1 if pins else 0


def main():
    try:
        with tempfile.TemporaryDirectory(prefix="check-action-pins-") as directory:
            return check(scanner(directory), os.environ.get("SCAN_PATH", "."))
    except (CheckError, OSError, subprocess.SubprocessError) as error:
        print(f"Action pin check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

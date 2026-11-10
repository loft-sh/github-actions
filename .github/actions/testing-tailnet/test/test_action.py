import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

SRC = Path(__file__).resolve().parents[1] / "src"


def load(name):
    spec = importlib.util.spec_from_file_location(name, SRC / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


preflight = load("preflight")
verify = load("verify")


@pytest.fixture
def env():
    return {"RUNNER_OS": "Linux", "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main", "INPUT_CLIENT_ID": "client-123", "INPUT_AUDIENCE": "api.tailscale.com/client-123", "INPUT_EXPECTED_TAILNET": "example-tailnet.ts.net"}


@pytest.fixture
def status():
    return {"BackendState": "Running", "CurrentTailnet": {"MagicDNSSuffix": "example-tailnet.ts.net"}, "Self": {"Tags": ["tag:e2e-github-runner"], "ID": "node-id", "TailscaleIPs": ["fd7a::1", "100.101.102.103"]}}


def test_valid_preflight(env):
    preflight.validate(env)


@pytest.mark.parametrize("key,value", [("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_EVENT_NAME", "pull_request_target"), ("GITHUB_REF", "refs/pull/12/merge"), ("RUNNER_OS", "Windows"), ("RUNNER_ENVIRONMENT", "self-hosted"), ("INPUT_CLIENT_ID", ""), ("INPUT_AUDIENCE", ""), ("INPUT_EXPECTED_TAILNET", ""), ("INPUT_AUDIENCE", "api.tailscale.com/other")])
def test_preflight_rejects_unsupported_context(env, key, value):
    env[key] = value
    with pytest.raises(ValueError):
        preflight.validate(env)


@pytest.mark.parametrize("change", [lambda s: s.update(BackendState="Stopped"), lambda s: s.update(CurrentTailnet={"MagicDNSSuffix": "wrong.ts.net"}), lambda s: s["Self"].update(Tags=["tag:e2e-github-runner", "tag:other"]), lambda s: s["Self"].update(Tags=[]), lambda s: s["Self"].update(ID=""), lambda s: s["Self"].update(TailscaleIPs=["invalid", "fd7a::1"])])
def test_verify_rejects_bad_status(status, change):
    change(status)
    with pytest.raises(ValueError):
        verify.verify(status, "example-tailnet.ts.net")


def test_verify_writes_outputs(status, monkeypatch, tmp_path):
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setenv("INPUT_EXPECTED_TAILNET", "example-tailnet.ts.net")
    monkeypatch.setattr(verify.subprocess, "run", lambda *args, **kwargs: SimpleNamespace(stdout=json.dumps(status)))
    assert verify.main() == 0
    assert output.read_text() == "ipv4=100.101.102.103\nnode-id=node-id\n"


def test_invalid_json_fails_without_outputs(monkeypatch, tmp_path):
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setenv("INPUT_EXPECTED_TAILNET", "example-tailnet.ts.net")
    monkeypatch.setattr(verify.subprocess, "run", lambda *args, **kwargs: SimpleNamespace(stdout="not json"))
    assert verify.main() == 1
    assert not output.exists()

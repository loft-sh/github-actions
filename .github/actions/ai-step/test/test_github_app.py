"""GitHub App rotation uses only the requested MCP credential and never logs secrets."""
import importlib.util
import io
import json
import sys
from pathlib import Path
from types import SimpleNamespace as Obj
from unittest.mock import Mock

import pytest

SRC = Path(__file__).resolve().parent.parent / "src" / "github_app.py"
spec = importlib.util.spec_from_file_location("github_app", SRC)
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
sys.modules["github_app"] = app


def credential(name="github-pr-writer", url=app.URL, kind="static_bearer"):
    return Obj(id=name, display_name=name, auth=Obj(type=kind, mcp_server_url=url))


@pytest.fixture
def setup(monkeypatch):
    now = [1000.0]
    monkeypatch.setattr(app.time, "time", lambda: now[0])
    minter = Mock(side_effect=lambda *args: ("secret-token", now[0] + 3600))
    monkeypatch.setattr(app, "mint", minter)
    api = Obj(list=Mock(return_value=[credential(), credential("linear", "https://mcp.linear.app/mcp", "mcp_oauth")]),
              update=Mock(), create=Mock())
    client = Obj(beta=Obj(vaults=Obj(credentials=api)))
    client.with_options = Mock(return_value=client)
    instance = app.GitHubCredential(client, "vlt", "123", "456", "PRIVATE KEY-----", "loft-sh/loft-enterprise")
    return instance, api, minter, now


def test_initial_and_timed_refresh_preserve_other_credentials(setup):
    instance, api, minter, now = setup
    instance.renew(force=True)
    assert api.update.call_args.args == ("github-pr-writer",)
    assert api.update.call_args.kwargs == {"vault_id": "vlt", "auth": {"type": "static_bearer", "token": "secret-token"}}
    now[0] += 2699
    instance.renew()
    assert minter.call_count == 1
    now[0] += 1
    instance.renew()
    assert minter.call_count == 2
    assert api.update.call_count == 2
    api.create.assert_not_called()


def test_shorter_expiry_renews_five_minutes_early(setup):
    instance, api, minter, now = setup
    minter.side_effect = lambda *args: ("token", now[0] + 900)
    instance.renew(force=True)
    now[0] += 599
    instance.renew()
    assert api.update.call_count == 1
    now[0] += 1
    instance.renew()
    assert api.update.call_count == 2


def test_short_lifetime_never_updates(setup):
    instance, api, minter, now = setup
    minter.side_effect = lambda *args: ("token", now[0] + 300)
    with pytest.raises(app.AppError, match="lifetime"):
        instance.renew(force=True)
    api.list.assert_not_called()
    api.update.assert_not_called()


@pytest.mark.parametrize("credentials", [
    [credential(), credential("other")],
    [credential(url=None), credential("other")],
    [credential(url=None), credential(url=None)],
    [credential(kind="mcp_oauth")],
    [credential(url=None, kind="mcp_oauth")],
    [credential(url="https://other.example/mcp")],
])
def test_ambiguous_or_wrong_credential_fails_closed(setup, credentials):
    instance, api, _, _ = setup
    api.list.return_value = credentials
    with pytest.raises(app.AppError):
        instance.renew(force=True)
    api.update.assert_not_called()
    api.create.assert_not_called()


def test_missing_write_only_url_matches_unique_known_name(setup):
    instance, api, _, _ = setup
    api.list.return_value = [credential(url=None), credential("linear", "https://mcp.linear.app/mcp", "mcp_oauth")]
    instance.renew(force=True)
    assert api.update.call_args.args == ("github-pr-writer",)
    api.create.assert_not_called()


def test_expiry_is_checked_again_immediately_before_update(setup):
    instance, api, _, now = setup
    def delayed_list(*args, **kwargs):
        now[0] += 3301
        return [credential()]
    api.list.side_effect = delayed_list
    with pytest.raises(app.AppError, match="lifetime"):
        instance.renew(force=True)
    api.update.assert_not_called()


def test_upstream_exception_does_not_expose_credentials(setup):
    instance, api, _, _ = setup
    api.update.side_effect = RuntimeError("PRIVATE KEY----- secret-token Authorization: Bearer secret")
    with pytest.raises(app.AppError) as error:
        instance.renew(force=True)
    assert "secret" not in str(error.value)
    assert error.value.__cause__ is None


def test_missing_github_credential_fails_without_writes(setup):
    instance, api, _, _ = setup
    api.list.return_value = [credential("linear", "https://mcp.linear.app/mcp", "mcp_oauth")]
    with pytest.raises(app.AppError, match="missing"):
        instance.renew(force=True)
    api.update.assert_not_called()
    api.create.assert_not_called()


def test_mint_requests_and_verifies_exact_repository_and_permissions(monkeypatch):
    response = {"token": "secret-token", "expires_at": "2030-01-01T00:00:00Z",
                "repositories": [{"full_name": "loft-sh/loft-enterprise"}],
                "permissions": app.PERMISSIONS}
    monkeypatch.setattr(app.subprocess, "run", lambda *a, **k: Obj(stdout=b"signature"))
    seen = []

    class Response(io.BytesIO):
        pass

    def open_request(request, timeout):
        seen.append((json.loads(request.data), timeout))
        return Response(json.dumps(response).encode())

    monkeypatch.setattr(app.urllib.request, "urlopen", open_request)
    token, _ = app.mint("123", "456", "key", "loft-sh/loft-enterprise")
    assert token == "secret-token"
    assert seen == [({"repositories": ["loft-enterprise"], "permissions": app.PERMISSIONS}, 30)]
    response["repositories"][0]["full_name"] = "other/loft-enterprise"
    with pytest.raises(app.AppError):
        app.mint("123", "456", "key", "loft-sh/loft-enterprise")
    response["repositories"][0]["full_name"] = "loft-sh/loft-enterprise"
    response["permissions"] = {**app.PERMISSIONS, "issues": "write"}
    with pytest.raises(app.AppError):
        app.mint("123", "456", "key", "loft-sh/loft-enterprise")

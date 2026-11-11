import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location("refresh_github", Path(__file__).parents[1] / "src/refresh_github.py")
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)


def test_renews_once_without_creating_session(monkeypatch):
    client = Mock()
    credential = Mock()
    factory = Mock(return_value=credential)
    monkeypatch.setitem(sys.modules, "anthropic", SimpleNamespace(Anthropic=Mock(return_value=client)))
    monkeypatch.setitem(sys.modules, "github_app", SimpleNamespace(GitHubCredential=factory))
    for name, value in {"INPUT_VAULT_ID": "vault", "INPUT_GITHUB_APP_ID": "123", "INPUT_GITHUB_APP_INSTALLATION_ID": "456", "INPUT_GITHUB_APP_PRIVATE_KEY": "key", "INPUT_GITHUB_APP_REPOSITORY": "owner/repo"}.items():
        monkeypatch.setenv(name, value)
    assert refresh.main() == 0
    factory.assert_called_once_with(client, "vault", "123", "456", "key", "owner/repo")
    credential.renew.assert_called_once_with(force=True)
    client.beta.sessions.create.assert_not_called()


def test_failure_does_not_print_exception(monkeypatch, capsys):
    monkeypatch.setitem(sys.modules, "anthropic", SimpleNamespace(Anthropic=Mock(side_effect=ValueError("secret"))))
    monkeypatch.setitem(sys.modules, "github_app", SimpleNamespace(GitHubCredential=Mock()))
    assert refresh.main() == 1
    assert "secret" not in capsys.readouterr().err

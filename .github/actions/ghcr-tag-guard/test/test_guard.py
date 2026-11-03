import importlib.util
import io
import json
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse

import pytest

PATH = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('guard', PATH / 'src' / 'guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
IMAGE = 'ghcr.io/loft-sh/kine:v0.13.0-loft.0'
NOCGO = IMAGE + '-nocgo'
DIGEST = 'sha256:' + 'a' * 64
UNKNOWN = json.dumps({'errors': [{'code': 'MANIFEST_UNKNOWN'}]}).encode()


class Response(io.BytesIO):
    def __init__(self, body=b'', headers=None):
        super().__init__(body)
        self.headers = headers or {}


class Registry:
    def __init__(self, manifests=None, token=None):
        self.manifests = dict(manifests or {})
        self.token = token if token is not None else (200, b'{"token":"opaque"}', {})
        self.calls = []

    def open(self, request, timeout):
        self.calls.append(request)
        assert request.get_method() == 'GET'
        assert timeout == 30
        path = urlparse(request.full_url).path
        result = self.token if path == '/token' else self.manifests.get(path.rsplit('/', 1)[-1], (404, UNKNOWN, {}))
        if isinstance(result, Exception):
            raise result
        status, body, headers = result
        if status != 200:
            raise HTTPError(request.full_url, status, 'error', headers, io.BytesIO(body))
        return Response(body, headers)


@pytest.fixture
def registry(monkeypatch):
    instance = Registry()
    monkeypatch.setattr(guard.urllib.request, 'build_opener', lambda *args: instance)
    return instance


def test_absent_is_safe_and_requests_are_read_only(registry, capsys):
    guard.guard(IMAGE, 'actor', 'secret')
    assert 'MANIFEST_UNKNOWN confirmed' in capsys.readouterr().out
    assert len(registry.calls) == 2
    assert 'repository%3Aloft-sh%2Fkine%3Apull' in registry.calls[0].full_url
    assert registry.calls[1].get_header('Authorization') == 'Bearer opaque'


@pytest.mark.parametrize('digest', [DIGEST, 'sha256:' + 'b' * 64])
def test_existing_digest_blocks_every_retry_without_mutation(registry, digest):
    registry.manifests['v0.13.0-loft.0'] = (200, b'{}', {'Docker-Content-Digest': digest})
    before = dict(registry.manifests)
    for _ in range(2):
        with pytest.raises(guard.Refusal) as error:
            guard.guard(IMAGE)
        assert IMAGE in str(error.value)
        assert digest in str(error.value)
        assert registry.manifests == before
    assert len(registry.calls) == 4


def test_nocgo_conflict_blocks_caller_before_any_publication(registry):
    registry.manifests['v0.13.0-loft.0-nocgo'] = (200, b'{}', {'Docker-Content-Digest': DIGEST})
    before = dict(registry.manifests)
    published = []
    with pytest.raises(guard.Refusal, match='nocgo'):
        guard.guard(f'{IMAGE}\n{NOCGO}')
        published.extend([IMAGE, NOCGO])
    assert not published
    assert registry.manifests == before
    assert len(registry.calls) == 3


@pytest.mark.parametrize('status', [401, 403, 429, 500])
@pytest.mark.parametrize('endpoint', ['token', 'manifest'])
def test_http_failures_block(registry, status, endpoint):
    response = (status, b'{}', {})
    if endpoint == 'token':
        registry.token = response
    else:
        registry.manifests['v0.13.0-loft.0'] = response
    with pytest.raises(guard.Refusal, match=str(status)):
        guard.guard(IMAGE)


@pytest.mark.parametrize('body', [
    b'{"errors":[{"code":"NAME_UNKNOWN"}]}',
    b'<html>not found</html>', b'', b'{}', b'{"errors":[]}',
    b'{"errors":[{"code":"MANIFEST_UNKNOWN"},{"code":"NAME_UNKNOWN"}]}',
])
def test_ambiguous_404_blocks(registry, body):
    registry.manifests['v0.13.0-loft.0'] = (404, body, {})
    with pytest.raises(guard.Refusal):
        guard.guard(IMAGE)


@pytest.mark.parametrize('body', [b'not json', b'{}', b'{"token":null}', b'{"token":123}', b'[]'])
def test_bad_token_response_blocks(registry, body):
    registry.token = (200, body, {})
    with pytest.raises(guard.Refusal):
        guard.guard(IMAGE)
    assert len(registry.calls) == 1


@pytest.mark.parametrize('digest', ['', 'sha256:bad'])
def test_existing_missing_or_invalid_digest_blocks(registry, digest):
    registry.manifests['v0.13.0-loft.0'] = (200, b'{}', {'Docker-Content-Digest': digest})
    with pytest.raises(guard.Refusal, match='digest'):
        guard.guard(IMAGE)


@pytest.mark.parametrize('error', [TimeoutError(), URLError('unavailable')])
def test_network_errors_block_without_secrets(registry, error):
    registry.token = error
    with pytest.raises(guard.Refusal) as exc:
        guard.guard(IMAGE, 'actor', 'secret')
    assert 'secret' not in str(exc.value)


@pytest.mark.parametrize('image', ['', 'ghcr.io/loft-sh/kine:latest', 'docker.io/loft-sh/kine:v1.0.0', 'ghcr.io/loft-sh/kine@sha256:' + 'a' * 64])
def test_invalid_reference_blocks_before_any_network(registry, image):
    with pytest.raises(guard.Refusal):
        guard.guard(f'{IMAGE}\n{image}' if image else image)
    assert registry.calls == []


def test_redirect_is_not_followed_with_credentials():
    req = guard.urllib.request.Request('https://ghcr.io/token', headers={'Authorization': 'Basic secret'})
    assert guard.NoRedirect().redirect_request(req, None, 302, 'Found', {}, 'https://elsewhere.example/') is None


def test_main_reads_action_environment_and_fails_closed(registry, monkeypatch, capsys):
    monkeypatch.setenv('INPUT_IMAGES', IMAGE)
    monkeypatch.setenv('REGISTRY_USERNAME', 'actor')
    monkeypatch.setenv('REGISTRY_TOKEN', 'secret')
    registry.manifests['v0.13.0-loft.0'] = (200, b'{}', {'Docker-Content-Digest': DIGEST})
    assert guard.main() == 1
    assert IMAGE in capsys.readouterr().err
    assert registry.calls[0].get_header('Authorization').startswith('Basic ')


@pytest.mark.parametrize('token', ['secret\r\nInjected: value', 'secret\x00', 'secret value', ''])
def test_invalid_bearer_token_is_redacted(registry, monkeypatch, capsys, token):
    registry.token = (200, json.dumps({'token': token}).encode(), {})
    monkeypatch.setenv('INPUT_IMAGES', IMAGE)
    monkeypatch.delenv('REGISTRY_USERNAME', raising=False)
    monkeypatch.delenv('REGISTRY_TOKEN', raising=False)
    assert guard.main() == 1
    err = capsys.readouterr().err
    assert 'secret' not in err
    assert 'Traceback' not in err
    assert len(registry.calls) == 1


def test_header_value_error_is_redacted(registry, monkeypatch, capsys):
    registry.token = ValueError('Invalid header value secret')
    monkeypatch.setenv('INPUT_IMAGES', IMAGE)
    assert guard.main() == 1
    err = capsys.readouterr().err
    assert 'secret' not in err
    assert 'Traceback' not in err

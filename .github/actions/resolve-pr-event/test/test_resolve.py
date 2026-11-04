import importlib.util
import io
import json
import os
from pathlib import Path
import zipfile

import pytest

spec = importlib.util.spec_from_file_location('resolve', Path(__file__).parents[1] / 'src/resolve.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
SHA = 'a' * 40
DEFAULT = 'b' * 40

def archive(data=None, name='event.json', extra=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr(name, data if data is not None else json.dumps({'number': 7, 'action': 'labeled', 'label': 'backport'}))
        if extra:
            z.writestr(extra, '{}')
    return buf.getvalue()

class FakeAPI:
    repo = 'org/repo'
    def __init__(self):
        self.run = {'id': 123, 'run_attempt': 1, 'event': 'pull_request_target', 'workflow_id': 42, 'repository': {'full_name': 'org/repo'}, 'status': 'completed', 'conclusion': 'success', 'path': r.RELAY, 'head_sha': SHA, 'head_branch': 'feature', 'head_repository': {'full_name': 'fork/repo'}}
        self.pr = {'number': 7, 'head': {'sha': SHA, 'ref': 'feature', 'repo': {'full_name': 'fork/repo'}}, 'base': {'repo': {'full_name': 'org/repo'}}, 'labels': [{'name': 'backport'}], 'merged': True, 'body': 'authoritative'}
        self.data = archive()
        self.items = [{'id': 9, 'name': 'pull-request-event-1', 'expired': False, 'workflow_run': {'id': 123}}]
    def get(self, path, binary=False, allow_missing=False):
        if path.startswith('/actions/runs/123/attempts/'):
            return self.run
        if path.startswith('/actions/workflows/'):
            return {'id': 42, 'path': r.RELAY}
        if path == '':
            return {'full_name': self.repo, 'default_branch': 'main', 'id': 12}
        if '/artifacts?' in path:
            return {'artifacts': self.items}
        if path.startswith('/actions/artifacts/'):
            return self.data
        if path.startswith('/pulls/'):
            return self.pr
        raise AssertionError(path)

def event(attempt=1):
    return {'action': 'completed', 'workflow_run': {'id': 123, 'run_attempt': attempt}}

def test_fork_event_uses_authoritative_pr():
    api = FakeAPI()
    result = r.resolve(api, event(), r.RELAY)
    assert result['pull_request']['body'] == 'authoritative'
    assert result['label']['name'] == 'backport'
    assert result['pull_request']['merged'] is True

def test_same_repo_branch():
    api = FakeAPI()
    api.run['head_repository']['full_name'] = api.pr['head']['repo']['full_name'] = 'org/repo'
    assert r.resolve(api, event(), r.RELAY)['number'] == 7

@pytest.mark.parametrize('field,value', [('event', 'pull_request'), ('event', 'push'), ('status', 'in_progress'), ('conclusion', 'failure'), ('path', 'wrong'), ('run_attempt', 2)])
def test_invalid_run(field, value):
    api = FakeAPI()
    api.run[field] = value
    with pytest.raises(r.Reject):
        r.resolve(api, event(), r.RELAY)

@pytest.mark.parametrize('change', ['number', 'base_repo', 'run_repo', 'workflow_id'])
def test_forged_pr_provenance(change):
    api = FakeAPI()
    if change == 'number': api.pr['number'] = 8
    if change == 'base_repo': api.pr['base']['repo']['full_name'] = 'other/repo'
    if change == 'run_repo': api.run['repository']['full_name'] = 'other/repo'
    if change == 'workflow_id': api.run['workflow_id'] = 99
    with pytest.raises(r.Reject): r.resolve(api, event(), r.RELAY)

def test_target_event_base_sha_and_deleted_fork():
    api = FakeAPI()
    api.pr['head']['sha'] = DEFAULT
    api.pr['head']['repo'] = None
    api.pr['merged'] = True
    assert r.resolve(api, event(), r.RELAY)['pull_request']['merged'] is True

def test_fork_head_cannot_change_relay():
    # Fake API rejects any contents lookup: the fork head can omit or modify
    # the relay, while pull_request_target executes the default branch workflow.
    api = FakeAPI()
    api.run['head_sha'] = 'c' * 40
    assert r.resolve(api, event(), r.RELAY)['number'] == 7

def test_stale_label():
    api = FakeAPI()
    api.pr['labels'] = []
    with pytest.raises(r.Reject, match='restore the label'): r.resolve(api, event(), r.RELAY)

def test_artifact_repository_mismatch():
    api = FakeAPI()
    api.items[0]['workflow_run']['repository_id'] = 999
    with pytest.raises(r.Reject): r.resolve(api, event(), r.RELAY)
    api.items[0]['workflow_run']['repository_id'] = 12
    assert r.resolve(api, event(), r.RELAY)['number'] == 7

def test_workflow_path_and_id_must_match():
    api = FakeAPI()
    api.run['workflow_id'] = 77
    with pytest.raises(r.Reject): r.resolve(api, event(), r.RELAY)
    api = FakeAPI()
    with pytest.raises(r.Reject): r.resolve(api, event(), '.github/workflows/other.yaml')

def test_attempt_specific_artifact():
    api = FakeAPI()
    api.run['run_attempt'] = 2
    with pytest.raises(r.Reject): r.resolve(api, event(2), r.RELAY)
    api.items[0]['name'] = 'pull-request-event-2'
    assert r.resolve(api, event(2), r.RELAY)['number'] == 7
    api.items.append(api.items[0].copy())
    with pytest.raises(r.Reject): r.resolve(api, event(2), r.RELAY)

@pytest.mark.parametrize('raw', [archive(name='../event.json'), archive(extra='second'), archive(data='{"number":7,"number":8,"action":"opened","label":""}'), archive(data='x' * (r.MAX_JSON + 1)), b'not a zip', b'x' * (r.MAX_ARCHIVE + 1), archive(data='{"number":7,"action":"opened","label":"","pull_request":{}}')])
def test_untrusted_archives(raw):
    with pytest.raises(r.Reject): r.decode_artifact(raw)

def test_restore_and_output_injection(tmp_path, monkeypatch):
    payload = {'action': 'opened', 'pull_request': {'number': 7, 'body': 'hello\nEOF\nother=evil'}, 'repository': {'full_name': 'org/repo'}}
    assert r.validate_restore(payload, 'org/repo') == payload
    with pytest.raises(r.Reject): r.validate_restore(payload, 'other/repo')
    output = tmp_path / 'out'
    monkeypatch.setenv('GITHUB_OUTPUT', str(output))
    monkeypatch.setenv('RUNNER_TEMP', str(tmp_path))
    r.write_outputs(payload)
    lines = output.read_text().splitlines()
    for index, line in enumerate(lines):
        if '<<' in line:
            delimiter = line.split('<<', 1)[1]
            assert lines.count(delimiter) == 1
    eventfile = next(tmp_path.glob('pr-event-*.json'))
    assert json.loads(eventfile.read_text()) == payload

def test_restore_rejects_bad_numbers():
    with pytest.raises(r.Reject): r.validate_restore({'action': 'opened', 'pull_request': {'number': True}, 'repository': {'full_name': 'org/repo'}}, 'org/repo')

@pytest.mark.parametrize('body,expected', [
    ('before<!-- private\ncomment -->after<!-- second -->\nEOF\nother=evil', 'beforeafter\nEOF\nother=evil'),
    (None, ''),
    ('keep normal text\nand an unfinished <!-- comment', 'keep normal text\nand an unfinished <!-- comment'),
])
def test_follow_up_description_preserves_text_without_html_comments(body, expected, tmp_path, monkeypatch):
    output = tmp_path / 'out'
    monkeypatch.setenv('GITHUB_OUTPUT', str(output))
    monkeypatch.setenv('RUNNER_TEMP', str(tmp_path))
    payload = {'action': 'opened', 'pull_request': {'number': 7, 'body': body}, 'repository': {'full_name': 'org/repo'}}
    r.write_outputs(payload)
    lines = output.read_text().splitlines()
    index = next(i for i, line in enumerate(lines) if line.startswith('body-without-comments<<'))
    delimiter = lines[index].split('<<', 1)[1]
    end = lines.index(delimiter, index + 1)
    assert '\n'.join(lines[index + 1:end]) == expected
    assert json.loads(next(tmp_path.glob('pr-event-*.json')).read_text()) == payload

def test_redirect_does_not_forward_token():
    import urllib.request
    request = urllib.request.Request('https://api.github.com/a', headers={'Authorization': 'Bearer secret'})
    redirected = r.SafeRedirect().redirect_request(request, None, 302, '', {}, 'https://storage.example/a')
    assert not redirected.has_header('Authorization')

def test_node_preload_restores_event_before_entry_point(tmp_path, monkeypatch):
    import subprocess
    payload = {'action': 'opened', 'pull_request': {'number': 7,
               'body': "require('fs').writeFileSync('executed', 'bad')",
               'title': "process.exit(42)"}, 'repository': {'full_name': 'org/repo'}}
    output = tmp_path / 'out'
    monkeypatch.setenv('GITHUB_OUTPUT', str(output))
    monkeypatch.setenv('RUNNER_TEMP', str(tmp_path))
    r.write_outputs(payload)
    lines = output.read_text().splitlines()
    index = next(i for i, line in enumerate(lines) if line.startswith('node-options<<'))
    node_options = lines[index + 1]
    resolved = next(tmp_path.glob('pr-event-*.json'))
    original = tmp_path / 'original.json'
    original.write_text('{"action":"completed"}')
    env = {**os.environ, 'GITHUB_EVENT_PATH': str(original), 'GITHUB_EVENT_NAME': 'workflow_run',
           'GITHUB_REPOSITORY': 'org/repo', 'RESOLVED_PR_EVENT_PATH': str(resolved),
           'NODE_OPTIONS': node_options}
    script = "const fs=require('node:fs'); const e=JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH)); console.log(JSON.stringify([process.env.GITHUB_EVENT_NAME,e.pull_request.number,e.pull_request.title]));"
    result = subprocess.run(['node', '-e', script], cwd=tmp_path, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == ['pull_request_target', 7, 'process.exit(42)']
    assert original.read_text() == '{"action":"completed"}'
    assert not (tmp_path / 'executed').exists()

@pytest.mark.parametrize('payload,path_set', [
    ('not json', True),
    ('{"pull_request":{"number":0},"repository":{"full_name":"org/repo"}}', True),
    ('{"pull_request":{"number":7},"repository":{"full_name":"other/repo"}}', True),
    ('{}', False),
])
def test_node_preload_invalid_event_fails_before_entry(tmp_path, payload, path_set):
    import subprocess
    path = tmp_path / 'payload.json'
    path.write_text(payload)
    preload = Path(r.__file__).parent / 'event-bootstrap.cjs'
    env = {**os.environ, 'GITHUB_REPOSITORY': 'org/repo',
           'NODE_OPTIONS': '--require=' + json.dumps(str(preload)),
           'RESOLVED_PR_EVENT_PATH': str(path) if path_set else ''}
    result = subprocess.run(['node', '-e', "console.log('entry-point-ran')"], env=env, capture_output=True, text=True)
    assert result.returncode != 0
    assert 'entry-point-ran' not in result.stdout
    assert payload not in result.stderr

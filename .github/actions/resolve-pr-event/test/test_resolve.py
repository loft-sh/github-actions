import importlib.util
import json
import os
import pathlib
import subprocess

import pytest

SRC = pathlib.Path(__file__).resolve().parents[1] / 'src'
spec = importlib.util.spec_from_file_location('resolver', SRC / 'resolve.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
A, B, C = ('a' * 40, 'b' * 40, 'c' * 40)
REPO = {'full_name': 'org/repo', 'default_branch': 'main'}

def pr(number, commit, fork=False):
    return {'number': number, 'state': 'closed', 'merged': True, 'merge_commit_sha': commit,
            'base': {'ref': 'main', 'repo': {'full_name': 'org/repo'}},
            'head': {'repo': {'full_name': 'fork/repo' if fork else 'org/repo'}, 'sha': B, 'ref': 'feature'},
            'labels': [{'name': 'backport-to-v1'}], 'body': 'hello'}

class FakeAPI:
    repo = 'org/repo'
    def __init__(self):
        self.pull = {1: pr(1, B, True), 2: pr(2, C)}
        self.calls = []
    def get(self, path):
        self.calls.append(path)
        if path == '': return REPO
        if path.startswith('/compare/'):
            return {'commits': [{'sha': B}, {'sha': C}], 'status': 'ahead'}
        if path.startswith('/commits/'):
            commit = path.split('/')[2]
            return [self.pull[1]] if commit == B else [self.pull[2], self.pull[1]]
        if path.startswith('/pulls/'): return self.pull[int(path.split('/')[-1])]
        raise AssertionError(path)

@pytest.fixture(autouse=True)
def context(monkeypatch):
    monkeypatch.setenv('GITHUB_REF', 'refs/heads/main')
    monkeypatch.setenv('GITHUB_WORKFLOW_REF', 'org/repo/.github/workflows/backport.yml@refs/heads/main')

def push():
    return {'repository': REPO, 'ref': 'refs/heads/main', 'before': A, 'after': C, 'deleted': False, 'forced': False}

def test_multi_commit_and_fork_merged_deduplicated():
    api = FakeAPI()
    events = r.resolve(api, push(), 'push')
    assert [x['number'] for x in events] == [1, 2]
    assert all(x['action'] == 'closed' for x in events)
    assert '/pulls/1' in api.calls and '/pulls/2' in api.calls

def test_nonmatching_and_unmerged_pr_skipped():
    api = FakeAPI()
    api.pull[1]['merged'] = False
    api.pull[2]['base']['repo']['full_name'] = 'other/repo'
    assert r.resolve(api, push(), 'push') == []

@pytest.mark.parametrize('field,value', [('ref', 'refs/heads/other'), ('forced', True), ('deleted', True), ('before', '0'*40)])
def test_invalid_push_does_not_query_range(field, value):
    api = FakeAPI(); payload = push(); payload[field] = value
    with pytest.raises(r.Reject): r.resolve(api, payload, 'push')
    assert len(api.calls) == 1

def test_untrusted_context_rejected(monkeypatch):
    api = FakeAPI(); payload = push(); payload['repository'] = {'full_name': 'other/repo'}
    with pytest.raises(r.Reject): r.resolve(api, payload, 'push')
    monkeypatch.setenv('GITHUB_REF', 'refs/heads/branch')
    with pytest.raises(r.Reject): r.resolve(api, push(), 'push')
    monkeypatch.setenv('GITHUB_REF', 'refs/heads/main')
    monkeypatch.setenv('GITHUB_WORKFLOW_REF', 'org/repo/.github/workflows/test.yml@refs/heads/branch')
    with pytest.raises(r.Reject): r.resolve(api, push(), 'push')

class SignalAPI(FakeAPI):
    def __init__(self):
        super().__init__()
        self.signal = {'id': 12, 'run_attempt': 1, 'event': 'pull_request', 'status': 'completed',
                       'conclusion': 'success', 'path': '.github/workflows/pull-request-events.yaml',
                       'workflow_id': 99, 'repository': REPO, 'head_branch': 'feature', 'head_sha': B,
                       'pull_requests': [{'number': 1}]}
    def get(self, path):
        if path.startswith('/actions/runs/'): return self.signal
        if path.startswith('/actions/workflows/'):
            return {'id': 99, 'path': '.github/workflows/pull-request-events.yaml'}
        return super().get(path)

def signal_payload():
    return {'repository': REPO, 'action': 'completed', 'workflow_run': {'id': 12, 'run_attempt': 1, 'head_sha': B}}

SOURCE = '.github/workflows/pull-request-events.yaml'

def test_signal_fork_pr_and_fallback():
    api = SignalAPI()
    assert [e['number'] for e in r.resolve(api, signal_payload(), 'workflow_run', SOURCE)] == [1]
    api.signal['pull_requests'] = []
    assert [e['number'] for e in r.resolve(api, signal_payload(), 'workflow_run', SOURCE)] == [1]
    assert not any('artifacts' in call for call in api.calls)

@pytest.mark.parametrize('field,value', [('conclusion', 'failure'), ('path', '.github/workflows/other.yaml'),
                                        ('head_branch', 'other'), ('head_sha', C), ('event', 'push'),
                                        ('repository', {'full_name': 'other/repo'})])
def test_invalid_signal(field, value):
    api = SignalAPI(); api.signal[field] = value
    try:
        assert r.resolve(api, signal_payload(), 'workflow_run', SOURCE) == []
    except r.Reject:
        pass

def test_unmerged_and_unrelated_signal_skipped():
    api = SignalAPI(); api.pull[1]['merged'] = False
    assert r.resolve(api, signal_payload(), 'workflow_run', SOURCE) == []
    api.pull[1] = pr(1, C); api.pull[1]['head']['sha'] = C
    assert r.resolve(api, signal_payload(), 'workflow_run', SOURCE) == []

def test_other_events_rejected():
    for name in ('pull_request', 'workflow_dispatch', 'schedule'):
        with pytest.raises(r.Reject): r.resolve(FakeAPI(), {'repository': REPO}, name)

def test_incomplete_range_fails():
    api = FakeAPI()
    payload = push(); payload['after'] = 'd'*40
    with pytest.raises(r.Reject): r.resolve(api, payload, 'push')

def test_outputs_escape_injection_and_node_preload(tmp_path, monkeypatch):
    monkeypatch.setenv('GITHUB_OUTPUT', str(tmp_path / 'out'))
    monkeypatch.setenv('RUNNER_TEMP', str(tmp_path))
    event = {'action': 'closed', 'number': 1, 'pull_request': pr(1, B), 'repository': REPO}
    event['pull_request']['body'] = 'hello\n::set-output name=x::bad\n<!-- secret -->'
    r.write_outputs([event])
    output = (tmp_path / 'out').read_text()
    assert 'events-json<<ghadelimiter_' in output
    assert 'set-output' not in output
    event_file = next(tmp_path.glob('pr-event-*.json'))
    env = dict(os.environ, GITHUB_REPOSITORY='org/repo', RESOLVED_PR_EVENT_PATH=str(event_file))
    result = subprocess.run(['node', '--require', str(SRC / 'event-bootstrap.cjs'), '-e',
                             "console.log(JSON.stringify([process.env.GITHUB_EVENT_NAME, JSON.parse(require('fs').readFileSync(process.env.GITHUB_EVENT_PATH)).number]))"],
                            env=env, text=True, capture_output=True, check=True)
    assert json.loads(result.stdout) == ['pull_request', 1]

def test_restore_rejected_on_untrusted_event(tmp_path, monkeypatch):
    event_file = tmp_path / 'payload.json'; event_file.write_text(json.dumps({'repository': REPO}))
    monkeypatch.setenv('GITHUB_EVENT_PATH', str(event_file))
    monkeypatch.setenv('GITHUB_OUTPUT', str(tmp_path / 'out'))
    monkeypatch.setenv('GITHUB_REPOSITORY', 'org/repo')
    monkeypatch.setenv('INPUT_GITHUB_TOKEN', 'unused')
    monkeypatch.setenv('GITHUB_EVENT_NAME', 'pull_request')
    monkeypatch.setenv('INPUT_EVENT_JSON', json.dumps({'number': 1}))
    monkeypatch.setattr(r, 'API', lambda *args: FakeAPI())
    assert r.main() == 0
    assert 'false' in (tmp_path / 'out').read_text()

def test_restore_rehydrates_current_labels_and_rejects_forged_sha(tmp_path, monkeypatch):
    event_file = tmp_path / 'payload.json'; event_file.write_text(json.dumps(push()))
    monkeypatch.setenv('GITHUB_EVENT_PATH', str(event_file))
    monkeypatch.setenv('GITHUB_OUTPUT', str(tmp_path / 'out'))
    monkeypatch.setenv('RUNNER_TEMP', str(tmp_path))
    monkeypatch.setenv('GITHUB_REPOSITORY', 'org/repo')
    monkeypatch.setenv('INPUT_GITHUB_TOKEN', 'unused')
    monkeypatch.setenv('GITHUB_EVENT_NAME', 'push')
    original = {'number': 1, 'action': 'closed', 'repository': REPO, 'pull_request': pr(1, B, True)}
    original['pull_request']['labels'] = []
    monkeypatch.setenv('INPUT_EVENT_JSON', json.dumps(original))
    monkeypatch.setattr(r, 'API', lambda *args: FakeAPI())
    assert r.main() == 0
    restored = json.loads(next(tmp_path.glob('pr-event-*.json')).read_text())
    assert restored['pull_request']['labels'] == [{'name': 'backport-to-v1'}]
    original['pull_request']['merge_commit_sha'] = A
    monkeypatch.setenv('INPUT_EVENT_JSON', json.dumps(original))
    (tmp_path / 'out').write_text('')
    assert r.main() == 0
    assert 'false' in (tmp_path / 'out').read_text()

def test_page_cap_fails_closed():
    class FullPages:
        def get(self, path): return [None] * 100
    with pytest.raises(r.Reject): r.paged(FullPages(), '/commits/x/pulls')

def test_large_bodies_do_not_inflate_matrix_output(tmp_path, monkeypatch):
    monkeypatch.setenv('GITHUB_OUTPUT', str(tmp_path / 'out'))
    events = []
    for n in range(1, 257):
        item = pr(n, B); item['body'] = 'x' * 65536
        events.append({'action': 'closed', 'number': n, 'repository': REPO, 'pull_request': item})
    r.write_outputs(events)
    assert (tmp_path / 'out').stat().st_size < 300000
    assert 'xxxxxx' not in (tmp_path / 'out').read_text()

def test_257_events_exceed_matrix_cap():
    class Many(FakeAPI):
        def get(self, path):
            if path.startswith('/commits/'):
                return [{'number': n, 'merge_commit_sha': B} for n in range(1, 258)]
            if path.startswith('/pulls/'):
                return pr(int(path.split('/')[-1]), B)
            return super().get(path)
    # A full page is not a valid API page, so use smaller batches.
    class ManyPaged(Many):
        def get(self, path):
            if path.startswith('/commits/'):
                page = int(path.rsplit('=', 1)[1])
                return [{'number': n, 'merge_commit_sha': B} for n in range((page-1)*100+1, min(page*100, 257)+1)]
            return super().get(path)
    with pytest.raises(RuntimeError): r.resolve(ManyPaged(), push(), 'push')

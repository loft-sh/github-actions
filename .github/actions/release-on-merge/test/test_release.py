import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'src' / 'release.py'


def git(repo, *args):
    return subprocess.run(['git', *args], cwd=repo, check=True, text=True, capture_output=True).stdout.strip()


@pytest.fixture
def fixture(tmp_path):
    repo = tmp_path / 'repo'
    repo.mkdir()
    git(repo, 'init', '-q')
    git(repo, 'config', 'user.email', 'test@example.com')
    git(repo, 'config', 'user.name', 'Test')
    mock = tmp_path / 'bin'
    mock.mkdir()
    gh = mock / 'gh'
    gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['GH_STATE'])
s = json.loads(p.read_text())
a = sys.argv[1:]
if a[:2] == ['release', 'create']:
    if s.get('fail_create'):
        print('publication failed', file=sys.stderr); sys.exit(1)
    s['release_args'] = a
    s['releases'][a[2]] = {'draft': False, 'prerelease': False}
elif a[0] == 'api':
    path = a[1]
    if '/git/ref/tags/' in path:
        tag = path.split('/git/ref/tags/')[1]
        if tag not in s['tags']:
            print('HTTP 404', file=sys.stderr); sys.exit(1)
        print(json.dumps({'object': {'type': 'commit', 'sha': s['tags'][tag]}}))
    elif '/releases/tags/' in path:
        tag = path.split('/releases/tags/')[1]
        if tag not in s['releases']:
            print('HTTP 404', file=sys.stderr); sys.exit(1)
        print(json.dumps(s['releases'][tag]))
    elif path.endswith('/git/refs'):
        vals = dict(x.split('=', 1) for x in a if '=' in x)
        tag = vals['ref'].removeprefix('refs/tags/')
        if tag in s['tags']:
            print('HTTP 422', file=sys.stderr); sys.exit(1)
        s['tags'][tag] = vals['sha']
        print('{}')
p.write_text(json.dumps(s))
''')
    gh.chmod(0o755)
    state = tmp_path / 'state.json'
    state.write_text(json.dumps({'tags': {}, 'releases': {}}))
    return repo, mock, state, tmp_path


def commit(repo, subject, body=None):
    args = ['commit', '--allow-empty', '-qm', subject]
    if body:
        args.extend(['-m', body])
    git(repo, *args)
    return git(repo, 'rev-parse', 'HEAD')


def invoke(fixture):
    repo, mock, state, tmp = fixture
    output = tmp / 'output'
    output.write_text('')
    env = dict(os.environ, PATH=f'{mock}:{os.environ["PATH"]}', GH_STATE=str(state),
               GITHUB_OUTPUT=str(output), GITHUB_REPOSITORY='owner/repo',
               INPUT_TARGET_SHA='HEAD', INPUT_INITIAL_VERSION='v0.0.0')
    result = subprocess.run([sys.executable, str(SCRIPT)], cwd=repo, env=env, text=True, capture_output=True)
    return result, dict(line.split('=', 1) for line in output.read_text().splitlines()), json.loads(state.read_text())


def remote(state, tags=None, releases=None, **kw):
    state.write_text(json.dumps({'tags': tags or {}, 'releases': releases or {}, **kw}))


@pytest.mark.parametrize(('subject', 'body', 'expected'), [
    ('feat: add feature', None, 'v0.1.0'),
    ('fix(ui): fix bug', None, 'v0.0.1'),
    ('refactor: clean up', None, 'v0.0.1'),
    ('feat(api)!: break contract', None, 'v0.1.0'),
    ('chore: upgrade', 'BREAKING CHANGE: removed API', 'v0.1.0'),
    ('docs: explain', 'The string BREAKING CHANGE: appears here.', ''),
    ('test: add coverage', None, ''),
])
def test_first_release_and_skip(fixture, subject, body, expected):
    sha = commit(fixture[0], subject, body)
    result, out, state = invoke(fixture)
    assert result.returncode == 0, result.stderr
    assert out == {'version': expected, 'revision': sha, 'released': str(bool(expected)).lower()}
    assert list(state['releases']) == ([expected] if expected else [])
    if expected:
        assert '--generate-notes' in state['release_args']
    else:
        assert 'release_args' not in state


def test_stable_annotated_tag_and_prerelease_ignored(fixture):
    repo, _, state, _ = fixture
    commit(repo, 'chore: init')
    git(repo, 'tag', '-a', 'v1.2.3', '-m', 'release')
    git(repo, 'tag', 'v9.0.0-rc.1')
    sha = commit(repo, 'fix: fix it')
    result, out, _ = invoke(fixture)
    assert result.returncode == 0, result.stderr
    assert out['version'] == 'v1.2.4' and out['revision'] == sha


def test_breaking_after_one_is_major(fixture):
    repo = fixture[0]
    commit(repo, 'chore: init')
    git(repo, 'tag', 'v1.2.3')
    commit(repo, 'fix(core)!: change api')
    result, out, _ = invoke(fixture)
    assert result.returncode == 0, result.stderr
    assert out['version'] == 'v2.0.0'


def test_retry_and_partial_publication(fixture):
    repo, _, state, _ = fixture
    sha = commit(repo, 'fix: change')
    remote(state, fail_create=True)
    result, _, saved = invoke(fixture)
    assert result.returncode != 0 and saved['tags']['v0.0.1'] == sha
    git(repo, 'tag', 'v0.0.1')
    remote(state, saved['tags'])
    result, out, saved = invoke(fixture)
    assert result.returncode == 0, result.stderr
    assert out['released'] == 'true' and 'v0.0.1' in saved['releases']
    result, out, _ = invoke(fixture)
    assert result.returncode == 0 and out['version'] == 'v0.0.1' and out['released'] == 'true'


def test_remote_collision_fails(fixture):
    commit(fixture[0], 'fix: change')
    remote(fixture[2], {'v0.0.1': 'a' * 40})
    result, _, state = invoke(fixture)
    assert result.returncode != 0 and not state['releases']


def test_shallow_fails(fixture):
    repo, _, _, tmp = fixture
    commit(repo, 'fix: change')
    shallow = tmp / 'shallow'
    subprocess.run(['git', 'clone', '-q', '--depth=1', f'file://{repo}', str(shallow)], check=True)
    changed = (shallow, *fixture[1:])
    result, _, _ = invoke(changed)
    assert result.returncode != 0 and 'full history' in result.stderr


def test_first_parent_ignores_side_branch(fixture):
    repo = fixture[0]
    commit(repo, 'chore: init')
    git(repo, 'checkout', '-qb', 'side')
    commit(repo, 'feat: side')
    git(repo, 'checkout', '-q', '-')
    git(repo, 'merge', '--no-ff', '-qm', 'chore: merge side', 'side')
    result, out, _ = invoke(fixture)
    assert result.returncode == 0 and out['released'] == 'false'


def test_missing_target_fails(fixture):
    commit(fixture[0], 'fix: change')
    git(fixture[0], 'checkout', '--detach', '-q')
    git(fixture[0], 'update-ref', '-d', 'HEAD')
    result, _, state = invoke(fixture)
    assert result.returncode != 0 and not state['tags']


def test_existing_release_on_different_target_fails(fixture):
    repo, _, state, _ = fixture
    commit(repo, 'fix: change')
    git(repo, 'tag', 'v0.0.1')
    remote(state, {'v0.0.1': 'a' * 40}, {'v0.0.1': {'draft': False, 'prerelease': False}})
    result, _, _ = invoke(fixture)
    assert result.returncode != 0 and 'does not point at target' in result.stderr


def test_crlf_breaking_footer(fixture):
    repo = fixture[0]
    commit(repo, 'chore: init')
    git(repo, 'tag', 'v1.2.3')
    message = fixture[3] / 'message'
    message.write_bytes(b'fix: change contract\r\n\r\nBREAKING CHANGE: removed api\r\n')
    git(repo, 'commit', '--allow-empty', '-q', '-F', str(message), '--cleanup=verbatim')
    result, out, _ = invoke(fixture)
    assert result.returncode == 0, result.stderr
    assert out['version'] == 'v2.0.0'

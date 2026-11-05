"""Enforce the trust boundary shared by callers, resolver and mutation jobs."""
from pathlib import Path
import os
import re
import subprocess
import textwrap

import pytest

GITHUB = Path(__file__).resolve().parents[3]
WORKFLOWS = GITHUB / 'workflows'


def jobs(name):
    text = (WORKFLOWS / name).read_text().split('\njobs:\n', 1)[1]
    return dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', text, re.M | re.S))


def test_no_privileged_pr_trigger_remains_anywhere_in_github():
    forbidden = b'pull_request' + b'_target'
    matches = [str(path.relative_to(GITHUB)) for path in GITHUB.rglob('*')
               if path.is_file() and '__pycache__' not in path.parts
               and forbidden in path.read_bytes()]
    assert matches == []


def test_backport_requires_trusted_default_branch_and_api_resolution():
    resolve = jobs('backport.yaml')['resolve-event']
    assert "inputs.pr-event != ''" in resolve
    assert '"push","workflow_run"' in resolve
    assert "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" in resolve
    assert "endsWith(github.workflow_ref, format('@refs/heads/{0}', github.event.repository.default_branch))" in resolve
    assert 'actions: read' in resolve
    assert 'pull-requests: read' in resolve
    assert 'contents: read' in resolve
    assert 'event-json: ${{ inputs.pr-event }}' in resolve


def test_every_backport_job_depends_on_authoritative_event():
    entries = jobs('backport.yaml')
    assert set(entries) == {'resolve-event', 'backport', 'fix-imports',
                           'legacy-classify', 'legacy-backport', 'link-backports'}
    for name, body in entries.items():
        assert 'permissions:\n      contents: read' in body, name
        assert 'contents: write' not in body, name
        if name != 'resolve-event':
            assert re.search(r'^    needs:.*resolve-event', body, re.M), name
            assert 'github.event.pull_request' not in body, name
    for name in ('backport', 'legacy-classify', 'link-backports'):
        assert "needs.resolve-event.outputs.eligible == 'true'" in entries[name]
    assert 'needs: [resolve-event, backport, legacy-backport]' in entries['link-backports']
    assert 'continue-on-error: true' in entries['link-backports']


def test_node_adapter_is_step_scoped_and_checkouts_never_persist_tokens():
    text = (WORKFLOWS / 'backport.yaml').read_text()
    assert 'NODE_OPTIONS: ${{ steps.pr-event.outputs.node-options }}' in text
    assert 'RESOLVED_PR_EVENT_PATH: ${{ steps.pr-event.outputs.event-path }}' in text
    assert 'GITHUB_EVENT_PATH:' not in text
    assert text.count('uses: actions/checkout@') == text.count('persist-credentials: false')
    assert 'cancel-in-progress: false' in text
    body = jobs('backport.yaml')['backport']
    assert body.count("if: steps.pr-event.outputs.eligible == 'true'") == 3


def test_review_rejects_forks_in_caller_and_reusable_before_secrets():
    for filename, job in [('claude-code-review.yaml', 'claude-review'),
                          ('test-claude-code-review.yaml', 'claude-review')]:
        body = jobs(filename)[job]
        assert 'github.event.pull_request.head.repo.full_name == github.repository' in body
        assert body.index('    if:') < body.index('    permissions:')
        assert 'contents: read' in body and 'pull-requests: write' in body
        assert 'allow-unsafe-pr-checkout' not in body
        assert 'Setup fork as origin' not in body
    review = jobs('claude-code-review.yaml')['claude-review']
    assert "github.event_name == 'pull_request'" in review
    assert 'persist-credentials: false' in review


@pytest.mark.parametrize('event,owner,head,expected', [
    ('pull_request', 'loft-sh', 'loft-sh/repo', True),
    ('pull_request' + '_target', 'loft-sh', 'loft-sh/repo', True),
    ('pull_request', 'loft-sh', 'fork/repo', False),
    ('pull_request' + '_target', 'loft-sh', 'fork/repo', False),
    ('push', 'loft-sh', 'loft-sh/repo', False),
    ('pull_request', 'other', 'loft-sh/repo', False),
])
def test_review_event_guard(event, owner, head, expected):
    body = jobs('claude-code-review.yaml')['claude-review']
    guard = body.split('    if: >-\n', 1)[1].split('    runs-on:', 1)[0].strip()
    # Translate only the expression operators and known context values, so the
    # cases exercise the actual guard rather than a separately written policy.
    expression = ' '.join(guard.split()).replace('&&', ' and ').replace('||', ' or ')
    expression = expression.replace("format('pull_request{0}', '_target')", repr('pull_request' + '_target'))
    expression = expression.replace('github.repository_owner', repr(owner))
    expression = expression.replace('github.event_name', repr(event))
    expression = expression.replace('github.event.pull_request.head.repo.full_name', repr(head))
    expression = expression.replace('github.repository', repr('loft-sh/repo'))
    assert eval(expression, {'__builtins__': {}}) is expected


def test_smoke_verifiers_need_no_token_permissions():
    for filename in ('test-backport.yaml', 'test-claude-code-review.yaml'):
        assert 'permissions: {}' in jobs(filename)['verify']
        text = (WORKFLOWS / filename).read_text()
        assert filename in text.split('permissions:', 1)[0]


@pytest.mark.parametrize('filename', ['claude.yaml', 'claude.yml'])
@pytest.mark.parametrize('association,is_pr,number,answer,exit_code,allowed,queried', [
    ('MEMBER', 'true', '17', 'true', 0, True, True),
    ('OWNER', 'true', '17', 'false', 0, False, True),
    ('COLLABORATOR', 'true', '17', 'true', 0, True, True),
    ('CONTRIBUTOR', 'true', '17', 'true', 0, False, False),
    ('MEMBER', 'false', '', 'true', 0, True, False),
    ('NONE', 'false', '', 'true', 0, False, False),
    ('MEMBER', 'true', '', 'true', 1, False, False),
    ('MEMBER', 'true', '$(touch injected)', 'true', 1, False, False),
    ('MEMBER', 'true', '17', '', 0, False, True),
])
def test_comment_authorization_executes_before_any_secret_or_checkout(
        tmp_path, filename, association, is_pr, number, answer, exit_code, allowed, queried):
    entries = jobs(filename)
    authorize, privileged = entries['authorize'], entries['claude']
    assert 'permissions:\n      pull-requests: read' in authorize
    assert 'secrets.' not in authorize and 'checkout@' not in authorize
    assert 'needs: authorize' in privileged
    assert "if: needs.authorize.outputs.allowed == 'true'" in privileged
    script = textwrap.dedent(authorize.split('        run: |\n', 1)[1])
    mock = tmp_path / 'gh'
    mock.write_text('#!/bin/sh\nprintf called > "$CALL_FILE"\nprintf "%s\\n" "$API_ANSWER"\n')
    mock.chmod(0o755)
    output, calls = tmp_path / 'out', tmp_path / 'calls'
    env = {**os.environ, 'PATH': str(tmp_path) + os.pathsep + os.environ['PATH'],
           'ASSOCIATION': association, 'IS_PR': is_pr, 'PR_NUMBER': number,
           'REPOSITORY': 'org/repo', 'API_ANSWER': answer,
           'GITHUB_OUTPUT': str(output), 'CALL_FILE': str(calls)}
    result = subprocess.run(['bash', '-euo', 'pipefail', '-c', script], env=env,
                            cwd=tmp_path, text=True, capture_output=True)
    assert result.returncode == exit_code, result.stderr
    assert (output.exists() and 'allowed=true' in output.read_text()) == allowed
    assert calls.exists() == queried
    assert not (tmp_path / 'injected').exists()



def test_claude_smoke_caller_matches_reusable_permissions_and_blocks_forks():
    caller = jobs('test-claude.yaml')['claude']
    assert 'github.event.pull_request.head.repo.full_name == github.repository' in caller
    assert 'contents: write' in caller and 'pull-requests: write' in caller
    assert 'permissions: {}' in jobs('test-claude.yaml')['verify']

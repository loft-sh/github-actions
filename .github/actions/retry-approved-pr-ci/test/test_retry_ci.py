import copy
import importlib.util
from pathlib import Path
import sys

import pytest

MODULE_PATH = Path(__file__).parents[1] / 'src' / 'retry_ci.py'
spec = importlib.util.spec_from_file_location('retry_ci', MODULE_PATH)
retry_ci = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = retry_ci
spec.loader.exec_module(retry_ci)

REPO = 'acme/project'
SHA = 'a' * 40
RUN_PATH = f'repos/{REPO}/actions/runs/123'
POST_PATH = RUN_PATH + '/rerun-failed-jobs'


def run(**changes):
    result = {
        'id': 123, 'workflow_id': 55, 'event': 'pull_request',
        'status': 'completed', 'conclusion': 'failure', 'head_sha': SHA,
        'run_attempt': 1, 'repository': {'full_name': REPO},
        'head_repository': {'full_name': REPO}, 'pull_requests': [{'number': 42}],
        'html_url': 'https://github.com/acme/project/actions/runs/123',
        'created_at': '2026-10-30T10:00:00Z',
    }
    result.update(changes)
    return result


def pr(**changes):
    result = {
        'number': 42, 'state': 'OPEN', 'isDraft': False, 'headRefOid': SHA,
        'headRepository': {'nameWithOwner': REPO},
        'baseRepository': {'nameWithOwner': REPO},
        'author': {'login': 'author'}, 'reviewDecision': 'APPROVED',
        'latestOpinionatedReviews': {
            'nodes': [{'state': 'APPROVED', 'commit': {'oid': SHA},
                       'author': {'login': 'reviewer', '__typename': 'User'}}],
            'pageInfo': {'hasNextPage': False},
        },
    }
    result.update(changes)
    return result


class API:
    def __init__(self):
        self.runs = [run()]
        self.prs = [pr()]
        self.pages = {1: [run()]}
        self.calls = []
        self.posts = []
        self.post_error = None

    @staticmethod
    def next_state(items):
        return copy.deepcopy(items.pop(0) if len(items) > 1 else items[0])

    def get(self, path):
        self.calls.append(('get', path))
        if path == RUN_PATH:
            return self.next_state(self.runs)
        if '/actions/workflows/55/runs?' in path:
            from urllib.parse import parse_qs, urlsplit
            params = parse_qs(urlsplit(path).query)
            page = int(params.get('page', ['1'])[0])
            return {'workflow_runs': copy.deepcopy(self.pages.get(page, [])),
                    'total_count': sum(map(len, self.pages.values()))}
        raise AssertionError(f'unexpected GET {path}')

    def graphql(self, query, variables):
        self.calls.append(('graphql', variables))
        return {'data': {'repository': {'pullRequest': self.next_state(self.prs)}}}

    def post(self, path):
        self.calls.append(('post', path))
        self.posts.append(path)
        if self.post_error:
            raise self.post_error


def config(**changes):
    values = dict(repository=REPO, run_id=123, run_attempt=1,
                  workflow_ids=frozenset({55}), max_retries=3,
                  enabled=True, dry_run=False)
    values.update(changes)
    return retry_ci.Config(**values)


def evaluate(api, **changes):
    return retry_ci.evaluate(config(**changes), api)


def assert_safe(result, api):
    assert result['outcome'] in {'skipped', 'exhausted', 'error'}
    assert not api.posts


def test_happy_path_revalidates_and_posts_once():
    api = API()
    result = evaluate(api)
    assert result['outcome'] == 'retried'
    assert api.posts == [POST_PATH]
    assert sum(call == ('get', RUN_PATH) for call in api.calls) == 2
    assert sum(call[0] == 'graphql' for call in api.calls) == 2
    assert result['head_sha'] == SHA
    assert result['retries_used'] == 0


def test_dry_run_checks_but_does_not_post():
    api = API()
    result = evaluate(api, dry_run=True)
    assert result['outcome'] == 'would_retry'
    assert any(call[0] == 'graphql' for call in api.calls)
    assert not api.posts


def test_disabled_has_no_api_calls():
    api = API()
    assert evaluate(api, enabled=False)['outcome'] == 'disabled'
    assert not api.calls


def test_attempt_four_is_exhausted_even_if_manually_rerun():
    api = API()
    api.runs = [run(run_attempt=4)]
    api.pages = {1: [run(run_attempt=4)]}
    result = evaluate(api, run_attempt=4)
    assert result['outcome'] == 'exhausted'
    assert result['retries_used'] == 3
    assert not api.posts


def test_attempt_mismatch_rejects_duplicate_event():
    api = API()
    api.runs = [run(run_attempt=2)]
    assert_safe(evaluate(api, run_attempt=1), api)


@pytest.mark.parametrize('change', [
    {'headRefOid': 'b' * 40}, {'reviewDecision': 'REVIEW_REQUIRED'},
    {'isDraft': True}, {'headRepository': {'nameWithOwner': 'other/fork'}},
    {'state': 'CLOSED'},
])
def test_pr_state_must_remain_eligible_before_write(change):
    api = API()
    api.prs = [pr(), pr(**change)]
    assert_safe(evaluate(api), api)


def test_newer_run_on_second_page_blocks_retry():
    api = API()
    # A full first page forces pagination even when the matching newer run is later.
    api.pages = {1: [run(id=123 - i, pull_requests=[{'number': 1000 + i}]) for i in range(100)],
                 2: [run(id=124, created_at='2026-10-30T10:01:00Z')]}
    assert_safe(evaluate(api), api)
    assert any('page=2' in call[1] for call in api.calls if call[0] == 'get')


@pytest.mark.parametrize('changed_run', [
    {'head_repository': {'full_name': 'other/fork'}},
    {'pull_requests': []}, {'pull_requests': [{'number': 42}, {'number': 43}]},
    {'event': 'push'}, {'status': 'in_progress'}, {'conclusion': 'success'},
    {'workflow_id': 99}, {'head_sha': None}, {'repository': None},
])
def test_ineligible_or_missing_run_metadata_fails_closed(changed_run):
    api = API()
    api.runs = [run(**changed_run)]
    assert_safe(evaluate(api), api)


@pytest.mark.parametrize('reviews', [
    {'nodes': [{'state': 'APPROVED', 'commit': {'oid': 'b' * 40},
                'author': {'login': 'reviewer', '__typename': 'User'}}], 'pageInfo': {'hasNextPage': False}},
    {'nodes': [{'state': 'CHANGES_REQUESTED', 'commit': {'oid': SHA},
                'author': {'login': 'reviewer', '__typename': 'User'}}], 'pageInfo': {'hasNextPage': False}},
    {'nodes': [], 'pageInfo': {'hasNextPage': False}},
    {'nodes': [], 'pageInfo': {'hasNextPage': True}},
])
def test_reviews_fail_closed(reviews):
    api = API()
    api.prs = [pr(latestOpinionatedReviews=reviews)]
    assert_safe(evaluate(api), api)


def test_malformed_response_fails_closed():
    api = API()
    api.prs = [None]
    assert_safe(evaluate(api), api)


def test_failed_post_is_not_retried():
    api = API()
    api.post_error = RuntimeError('network error')
    result = evaluate(api)
    assert result['outcome'] == 'error'
    assert api.posts == [POST_PATH]


@pytest.mark.parametrize('changes', [
    {'repository': 'bad'}, {'repository': '../bad'}, {'run_id': 0},
    {'run_attempt': 0}, {'workflow_ids': frozenset()}, {'workflow_ids': frozenset({0})},
    {'max_retries': -1}, {'max_retries': 4}, {'enabled': 'true'}, {'dry_run': 1},
])
def test_invalid_configuration_is_rejected_even_in_dry_run(changes):
    cfg = config(**changes)
    with pytest.raises(ValueError):
        cfg.validate()


def test_run_attempt_changes_before_write():
    api = API()
    api.runs = [run(), run(run_attempt=2)]
    assert_safe(evaluate(api), api)


def test_newer_run_appearing_before_write_blocks_post():
    class NewRunAPI(API):
        def __init__(self):
            super().__init__()
            self.list_reads = 0

        def get(self, path):
            if '/actions/workflows/55/runs?' in path:
                self.list_reads += 1
                if self.list_reads == 2:
                    self.pages = {1: [run(id=124, created_at='2026-10-30T10:01:00Z'), run()]}
            return super().get(path)

    api = NewRunAPI()
    assert_safe(evaluate(api), api)
    assert api.list_reads >= 2


def test_exhausted_handoff_contains_only_verified_identifiers():
    import json
    api = API()
    api.runs = [run(run_attempt=4, name='untrusted\ninjected=1')]
    api.pages = {1: [run(run_attempt=4)]}
    result = evaluate(api, run_attempt=4)
    assert result['outcome'] == 'exhausted'
    assert json.loads(result['diagnosis']) == {
        'version': 1, 'repository': REPO, 'pr_number': 42, 'head_sha': SHA,
        'workflow_id': 55, 'run_id': 123, 'run_attempt': 4,
        'run_url': 'https://github.com/acme/project/actions/runs/123',
        'reason': 'retry_budget_exhausted',
    }
    assert not api.posts
    assert all(call[0] in {'get', 'graphql'} for call in api.calls)


@pytest.mark.parametrize('author', [
    {'login': 'reviewer', '__typename': 'Bot'},
    {'login': 'author', '__typename': 'User'},
])
def test_bot_or_pr_author_cannot_supply_approval(author):
    api = API()
    api.prs = [pr(latestOpinionatedReviews={
        'nodes': [{'state': 'APPROVED', 'commit': {'oid': SHA}, 'author': author}],
        'pageInfo': {'hasNextPage': False},
    })]
    assert_safe(evaluate(api), api)


@pytest.mark.parametrize('budget,attempt,expected', [
    (0, 1, 'exhausted'), (0, 2, 'exhausted'), (0, 3, 'exhausted'), (0, 4, 'exhausted'),
    (3, 1, 'retried'), (3, 2, 'retried'), (3, 3, 'retried'), (3, 4, 'exhausted'),
])
def test_retry_budget_boundaries(budget, attempt, expected):
    api = API()
    api.runs = [run(run_attempt=attempt)]
    api.pages = {1: [run(run_attempt=attempt)]}
    result = evaluate(api, max_retries=budget, run_attempt=attempt)
    assert result['outcome'] == expected
    assert result['retries_used'] == attempt - 1
    assert api.posts == ([POST_PATH] if expected == 'retried' else [])
    assert all('/merge' not in str(call) for call in api.calls)


@pytest.mark.parametrize('failure_point', ['run', 'graphql', 'listing'])
def test_api_read_errors_fail_closed_and_do_not_echo_error(failure_point):
    class BrokenAPI(API):
        def get(self, path):
            if (failure_point == 'run' and path == RUN_PATH or
                    failure_point == 'listing' and '/actions/workflows/' in path):
                raise RuntimeError('secret-token-and-untrusted-message')
            return super().get(path)

        def graphql(self, query, variables):
            if failure_point == 'graphql':
                raise RuntimeError('secret-token-and-untrusted-message')
            return super().graphql(query, variables)

    api = BrokenAPI()
    result = evaluate(api)
    assert result['outcome'] == 'error'
    assert 'secret-token' not in str(result)
    assert not api.posts


def test_main_writes_safe_output_and_summary(monkeypatch, tmp_path, capsys):
    import json
    api = API()
    api.runs = [run(run_attempt=4, name='untrusted\ninjected=1')]
    api.pages = {1: [run(run_attempt=4)]}
    output = tmp_path / 'output'
    summary = tmp_path / 'summary'
    for key, value in {
        'GITHUB_REPOSITORY': REPO, 'INPUT_RUN_ID': '123', 'INPUT_RUN_ATTEMPT': '4',
        'INPUT_WORKFLOW_IDS': '55', 'INPUT_MAX_RETRIES': '3', 'INPUT_ENABLED': 'true',
        'INPUT_DRY_RUN': 'false', 'GITHUB_OUTPUT': str(output),
        'GITHUB_STEP_SUMMARY': str(summary),
    }.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setattr(retry_ci, 'GitHub', lambda: api)
    assert retry_ci.main() == 0
    result = json.loads(capsys.readouterr().out)
    outputs = dict(line.split('=', 1) for line in output.read_text().splitlines())
    assert json.loads(outputs['diagnosis']) == json.loads(result['diagnosis'])
    assert outputs['outcome'] == 'exhausted'
    assert 'inspect the failed jobs' in summary.read_text()
    assert 'untrusted' not in output.read_text() + summary.read_text()
    assert not api.posts


def test_main_invalid_input_cannot_inject_output(monkeypatch, tmp_path, capsys):
    import json
    output = tmp_path / 'output'
    summary = tmp_path / 'summary'
    monkeypatch.setenv('GITHUB_REPOSITORY', 'acme/project\ninjected=token')
    monkeypatch.setenv('INPUT_RUN_ID', '123')
    monkeypatch.setenv('INPUT_RUN_ATTEMPT', '1')
    monkeypatch.setenv('INPUT_WORKFLOW_IDS', '55')
    monkeypatch.setenv('GITHUB_OUTPUT', str(output))
    monkeypatch.setenv('GITHUB_STEP_SUMMARY', str(summary))
    assert retry_ci.main() == 0
    assert json.loads(capsys.readouterr().out) == {'outcome': 'error', 'reason': 'invalid_configuration'}
    assert output.read_text() == 'outcome=error\nreason=invalid_configuration\n'
    assert 'injected' not in summary.read_text()

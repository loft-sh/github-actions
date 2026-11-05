#!/usr/bin/env python3
"""Resolve merged pull requests using trusted GitHub events and API data."""
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid

MAX_BYTES = 4 * 1024 * 1024
SHA = re.compile(r'^[0-9a-f]{40}$')

class Reject(Exception):
    pass

def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Reject('duplicate JSON key')
        result[key] = value
    return result

def parse_json(data):
    try:
        return json.loads(data, object_pairs_hook=unique_pairs)
    except (ValueError, UnicodeDecodeError, RecursionError) as exc:
        raise Reject('invalid JSON') from exc

def positive(value):
    return type(value) is int and 0 < value <= 2**53 - 1

def sha(value):
    return isinstance(value, str) and bool(SHA.fullmatch(value)) and value != '0' * 40

def same(left, right):
    return isinstance(left, str) and isinstance(right, str) and left.lower() == right.lower()

class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc:
            redirected.remove_header('Authorization')
        return redirected

class API:
    def __init__(self, token, repository):
        self.root = os.environ.get('GITHUB_API_URL', 'https://api.github.com').rstrip('/')
        self.repo = repository
        self.token = token

    def get(self, path):
        request = urllib.request.Request(self.root + '/repos/' + self.repo + path,
            headers={'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
                     'X-GitHub-Api-Version': '2022-11-28'})
        try:
            with urllib.request.build_opener(SafeRedirect()).open(request, timeout=30) as response:
                raw = response.read(MAX_BYTES + 1)
        except urllib.error.HTTPError as exc:
            raise RuntimeError('GitHub API request failed (HTTP %d)' % exc.code) from exc
        except urllib.error.URLError as exc:
            raise RuntimeError('GitHub API request failed') from exc
        if len(raw) > MAX_BYTES:
            raise Reject('API response too large')
        return parse_json(raw)

def paged(api, path, field=None):
    items = []
    for page in range(1, 11):
        obj = api.get(path + ('&' if '?' in path else '?') + 'per_page=100&page=%d' % page)
        batch = obj.get(field) if field and isinstance(obj, dict) else obj
        if not isinstance(batch, list) or len(batch) > 100:
            raise Reject('invalid paginated API response')
        items.extend(batch)
        if len(batch) < 100:
            return items
    raise Reject('pagination limit exceeded')

def trusted_context(api, payload, event_name):
    repo = api.get('')
    default = repo.get('default_branch')
    if not same(repo.get('full_name'), api.repo) or not isinstance(default, str) or not default:
        raise Reject('repository identity mismatch')
    if not same((payload.get('repository') or {}).get('full_name'), api.repo):
        raise Reject('event repository mismatch')
    ref = 'refs/heads/' + default
    if os.environ.get('GITHUB_REF') != ref:
        raise Reject('workflow is not running on the default branch')
    workflow_ref = os.environ.get('GITHUB_WORKFLOW_REF', '')
    if not workflow_ref.startswith(api.repo + '/.github/workflows/') or not workflow_ref.endswith('@' + ref):
        raise Reject('workflow revision is not trusted')
    return repo, default, ref

def merged_pr(pr, number, repo, default):
    base = pr.get('base') or {}
    return (positive(number) and pr.get('number') == number and pr.get('merged') is True and
            pr.get('state') == 'closed' and sha(pr.get('merge_commit_sha')) and
            same((base.get('repo') or {}).get('full_name'), repo) and base.get('ref') == default)

def resolve(api, payload, event_name, source_workflow='', requested_number=None):
    if not isinstance(payload, dict):
        raise Reject('invalid event')
    repo, default, ref = trusted_context(api, payload, event_name)
    if requested_number is not None and not positive(requested_number):
        raise Reject('invalid restored pull request number')
    commits = []
    if event_name == 'push':
        before, head = payload.get('before'), payload.get('after')
        if payload.get('ref') != ref or payload.get('deleted') is not False or payload.get('forced') is not False or not sha(before) or not sha(head):
            raise Reject('unsupported push ref, range, deletion, or force push')
        if requested_number is None:
            commits = [item.get('sha') for item in paged(api, '/compare/%s...%s' % (before, head), 'commits') if isinstance(item, dict)]
            if not commits or commits[-1] != head or any(not sha(item) for item in commits):
                raise Reject('invalid or incomplete push range')
    elif event_name == 'workflow_run':
        signal = payload.get('workflow_run') or {}
        run_id, attempt = signal.get('id'), signal.get('run_attempt')
        if (payload.get('action') != 'completed' or not positive(run_id) or not positive(attempt) or
            not re.fullmatch(r'\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml', source_workflow)):
            raise Reject('invalid signal identity')
        run = api.get('/actions/runs/%d/attempts/%d' % (run_id, attempt))
        workflow = api.get('/actions/workflows/' + urllib.parse.quote(source_workflow.rsplit('/', 1)[-1], safe=''))
        if (run.get('id') != run_id or run.get('run_attempt') != attempt or
            run.get('event') != 'pull_request' or run.get('status') != 'completed' or run.get('conclusion') != 'success' or
            run.get('path') != source_workflow or not positive(run.get('workflow_id')) or
            workflow.get('id') != run.get('workflow_id') or workflow.get('path') != source_workflow or
            not same((run.get('repository') or {}).get('full_name'), api.repo) or
            not isinstance(run.get('head_branch'), str) or not run.get('head_branch') or
            not sha(run.get('head_sha')) or signal.get('head_sha') != run.get('head_sha')):
            raise Reject('signal run is not eligible')
        candidates = run.get('pull_requests')
        if not isinstance(candidates, list):
            raise Reject('invalid signal pull request associations')
        if not candidates:
            candidates = paged(api, '/commits/%s/pulls' % run['head_sha'])
        signal_sha = run['head_sha']
    else:
        raise Reject('unsupported event')
    # Push restoration rechecks one selected PR and its default-branch ancestry.
    # Only selection needs to discover PRs across the full pushed commit range.
    numbers = {requested_number} if event_name == 'push' and requested_number is not None else set()
    for commit in commits:
        for candidate in paged(api, '/commits/%s/pulls' % commit):
            number = candidate.get('number') if isinstance(candidate, dict) else None
            if positive(number) and candidate.get('merge_commit_sha') == commit:
                numbers.add(number)
    if event_name == 'workflow_run':
        for candidate in candidates:
            number = candidate.get('number') if isinstance(candidate, dict) else None
            if positive(number):
                numbers.add(number)
    events = []
    for number in sorted(numbers):
        pr = api.get('/pulls/%d' % number)
        if not isinstance(pr, dict) or not merged_pr(pr, number, api.repo, default):
            continue
        if commits and pr['merge_commit_sha'] not in commits:
            continue
        if event_name == 'workflow_run' and (signal_sha not in (pr['merge_commit_sha'], (pr.get('head') or {}).get('sha')) or
                                            (pr.get('head') or {}).get('ref') != run['head_branch'] or
                                            not same((run.get('head_repository') or {}).get('full_name'),
                                                     ((pr.get('head') or {}).get('repo') or {}).get('full_name'))):
            continue
        if not commits:
            comparison = api.get('/compare/%s...%s' % (pr['merge_commit_sha'], urllib.parse.quote(default, safe='')))
            if comparison.get('status') not in ('ahead', 'identical'):
                raise Reject('merged commit is not on the default branch')
        events.append({'action': 'closed', 'number': number, 'pull_request': pr, 'repository': repo})
    if len(events) > 256:
        raise RuntimeError('too many matched pull requests for a job matrix')
    return events

def compact(event):
    pr = event['pull_request']
    repo = event['repository']
    labels = [label for label in pr.get('labels', []) if isinstance(label, dict) and
              isinstance(label.get('name'), str) and label['name'].startswith('backport-to-')]
    return {'action': 'closed', 'number': event['number'],
            'repository': {'full_name': repo['full_name'], 'name': repo.get('name', repo['full_name'].split('/')[-1]),
                           'default_branch': repo['default_branch']},
            'pull_request': {'number': pr['number'], 'state': pr['state'], 'merged': pr['merged'],
                             'merge_commit_sha': pr['merge_commit_sha'], 'base': {'ref': pr['base']['ref'],
                                 'repo': {'full_name': pr['base']['repo']['full_name']}},
                             'labels': [{'name': item['name']} for item in labels]}}

def write_output_values(outputs):
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
        for key, value in outputs.items():
            delimiter = 'ghadelimiter_' + uuid.uuid4().hex
            while delimiter in value:
                delimiter = 'ghadelimiter_' + uuid.uuid4().hex
            f.write('%s<<%s\n%s\n%s\n' % (key, delimiter, value, delimiter))

def write_outputs(events):
    encoded_events = json.dumps([compact(event) for event in events], ensure_ascii=True, separators=(',', ':'))
    outputs = {'eligible': 'true' if events else 'false', 'events-json': encoded_events}
    if len(events) == 1:
        event = events[0]
        encoded = json.dumps(event, ensure_ascii=True, separators=(',', ':'))
        compact_encoded = json.dumps(compact(event), ensure_ascii=True, separators=(',', ':'))
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=os.environ['RUNNER_TEMP'], prefix='pr-event-', suffix='.json', delete=False) as f:
            f.write(encoded)
            path = f.name
        bootstrap = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'event-bootstrap.cjs')
        outputs.update({'event-json': compact_encoded, 'event-path': path,
            'node-options': '--require=' + json.dumps(bootstrap, ensure_ascii=False),
            'pr-number': str(event['number']), 'action': event['action']})
    if sum(len(value.encode('utf-16-le')) for value in outputs.values()) > 700 * 1024:
        raise RuntimeError('resolved outputs exceed size limit')
    write_output_values(outputs)

def main():
    try:
        repository = os.environ['GITHUB_REPOSITORY']
        with open(os.environ['GITHUB_EVENT_PATH'], 'rb') as f:
            raw = f.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise Reject('event too large')
        payload = parse_json(raw)
        restored = os.environ.get('INPUT_EVENT_JSON', '')
        requested = None
        number = None
        if restored:
            if len(restored.encode('utf-8')) > MAX_BYTES:
                raise Reject('restored event too large')
            requested = parse_json(restored)
            number = requested.get('number') if isinstance(requested, dict) else None
            if not positive(number):
                raise Reject('invalid restored pull request number')
        events = resolve(API(os.environ['INPUT_GITHUB_TOKEN'], repository), payload,
                         os.environ.get('GITHUB_EVENT_NAME', ''), os.environ.get('INPUT_SOURCE_WORKFLOW', ''),
                         requested_number=number)
        if restored:
            matches = [event for event in events if event['number'] == number]
            supplied_pr = requested.get('pull_request') if isinstance(requested, dict) else None
            if (len(matches) != 1 or not isinstance(supplied_pr, dict) or
                requested.get('action') != 'closed' or supplied_pr.get('number') != number or
                supplied_pr.get('merged') is not True or supplied_pr.get('state') != 'closed' or
                supplied_pr.get('merge_commit_sha') != matches[0]['pull_request']['merge_commit_sha'] or
                not same((requested.get('repository') or {}).get('full_name'), repository) or
                not same(((supplied_pr.get('base') or {}).get('repo') or {}).get('full_name'), repository) or
                (supplied_pr.get('base') or {}).get('ref') != matches[0]['repository']['default_branch']):
                raise Reject('restored event does not match authoritative event')
            events = matches
        write_outputs(events)
    except Reject as exc:
        print('::warning::' + str(exc))
        write_output_values({'eligible': 'false', 'events-json': '[]'})
    except RuntimeError as exc:
        print('::error::Unable to resolve pull request event: ' + str(exc), file=sys.stderr)
        return 1
    except (OSError, KeyError, TypeError) as exc:
        print('::error::Unable to resolve pull request event: ' + type(exc).__name__, file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())

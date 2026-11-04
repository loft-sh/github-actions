#!/usr/bin/env python3
"""Resolve an untrusted workflow_run artifact into an authoritative PR event."""
import io
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

MAX_ARCHIVE = 128 * 1024
MAX_JSON = 32 * 1024
RELAY = '.github/workflows/pull-request-events.yaml'
ACTIONS = {'opened', 'edited', 'labeled', 'closed'}

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

def decode_artifact(raw):
    if len(raw) > MAX_ARCHIVE:
        raise Reject('artifact archive too large')
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            entries = archive.infolist()
            if len(entries) != 1 or entries[0].filename != 'event.json':
                raise Reject('artifact must contain only event.json')
            entry = entries[0]
            if entry.is_dir() or entry.file_size > MAX_JSON or entry.flag_bits & 1:
                raise Reject('invalid artifact member')
            with archive.open(entry) as member:
                data = member.read(MAX_JSON + 1)
            if len(data) > MAX_JSON:
                raise Reject('artifact member too large')
    except (zipfile.BadZipFile, RuntimeError, OSError, EOFError) as exc:
        raise Reject('invalid artifact archive') from exc
    obj = parse_json(data)
    if not isinstance(obj, dict) or set(obj) != {'number', 'action', 'label'}:
        raise Reject('invalid artifact fields')
    if not positive(obj['number']) or obj['action'] not in ACTIONS:
        raise Reject('invalid artifact event')
    label = obj['label']
    if not isinstance(label, str) or len(label) > 255 or any(ord(c) < 32 for c in label):
        raise Reject('invalid artifact label')
    if (obj['action'] == 'labeled') != bool(label):
        raise Reject('invalid event label')
    return obj

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

    def get(self, path, binary=False, allow_missing=False):
        request = urllib.request.Request(self.root + '/repos/' + self.repo + path,
            headers={'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
                     'X-GitHub-Api-Version': '2022-11-28'})
        try:
            with urllib.request.build_opener(SafeRedirect()).open(request, timeout=30) as response:
                raw = response.read((MAX_ARCHIVE if binary else 4 * 1024 * 1024) + 1)
        except urllib.error.HTTPError as exc:
            if allow_missing and exc.code == 404:
                return None
            raise RuntimeError('GitHub API request failed (HTTP %d)' % exc.code) from exc
        except urllib.error.URLError as exc:
            raise RuntimeError('GitHub API request failed') from exc
        if len(raw) > (MAX_ARCHIVE if binary else 4 * 1024 * 1024):
            raise Reject('API response too large')
        return raw if binary else parse_json(raw)

def resolve(api, event, source):
    if source != RELAY:
        raise Reject('source-workflow must name the pull request relay')
    if not isinstance(event, dict) or event.get('action') != 'completed':
        raise Reject('not a completed workflow run')
    payload_run = event.get('workflow_run') or {}
    run_id, attempt = payload_run.get('id'), payload_run.get('run_attempt')
    if not positive(run_id) or not positive(attempt):
        raise Reject('invalid run identity')
    run = api.get('/actions/runs/%d/attempts/%d' % (run_id, attempt))
    if (run.get('id') != run_id or run.get('run_attempt') != attempt or
        run.get('event') != 'pull_request_target' or run.get('status') != 'completed' or
        run.get('conclusion') != 'success' or run.get('path') != source):
        raise Reject('source run is not an eligible relay')
    workflow = api.get('/actions/workflows/' + urllib.parse.quote(source.rsplit('/', 1)[-1], safe=''))
    run_repo = run.get('repository') or {}
    if (not positive(run.get('workflow_id')) or workflow.get('id') != run.get('workflow_id') or
        workflow.get('path') != source or not isinstance(run_repo.get('full_name'), str) or
        run_repo['full_name'].lower() != api.repo.lower()):
        raise Reject('source workflow or repository mismatch')
    # pull_request_target executes the workflow from the base repository's
    # default branch. The run head_sha is the PR head, not the workflow SHA.
    repo = api.get('')
    if repo.get('full_name', '').lower() != api.repo.lower():
        raise Reject('repository identity mismatch')
    artifacts = []
    for page in range(1, 11):
        result = api.get('/actions/runs/%d/artifacts?per_page=100&page=%d' % (run_id, page))
        batch = result.get('artifacts', [])
        artifacts.extend(a for a in batch if a.get('name') == 'pull-request-event-%d' % attempt and not a.get('expired'))
        if len(batch) < 100:
            break
    else:
        raise Reject('too many artifacts')
    if len(artifacts) != 1:
        raise Reject('missing or ambiguous relay artifact; rerun the metadata relay')
    artifact = artifacts[0]
    if not positive(artifact.get('id')) or artifact.get('workflow_run', {}).get('id') != run_id:
        raise Reject('artifact run mismatch')
    artifact_repo_id = artifact.get('workflow_run', {}).get('repository_id')
    if artifact_repo_id is not None and artifact_repo_id != repo.get('id'):
        raise Reject('artifact repository mismatch')
    seed = decode_artifact(api.get('/actions/artifacts/%d/zip' % artifact['id'], binary=True))
    pr = api.get('/pulls/%d' % seed['number'], allow_missing=True)
    if not isinstance(pr, dict) or pr.get('number') != seed['number']:
        raise Reject('pull request not found')
    base_repo = ((pr.get('base') or {}).get('repo') or {}).get('full_name')
    if not isinstance(base_repo, str) or base_repo.lower() != api.repo.lower():
        raise Reject('pull request repository mismatch')
    label = None
    if seed['action'] == 'labeled':
        label = next((item for item in pr.get('labels', []) if isinstance(item, dict) and item.get('name') == seed['label']), None)
        if label is None:
            raise Reject('label no longer exists on pull request; restore the label and rerun the metadata relay')
    result = {'action': seed['action'], 'number': seed['number'], 'pull_request': pr, 'repository': repo}
    if label is not None:
        result['label'] = label
    return result

def validate_restore(event, repository):
    if not isinstance(event, dict) or not isinstance(event.get('pull_request'), dict):
        raise Reject('invalid restored event')
    number = event['pull_request'].get('number')
    repo = event.get('repository')
    if not positive(number) or not isinstance(repo, dict) or not isinstance(repo.get('full_name'), str) or repo['full_name'].lower() != repository.lower():
        raise Reject('restored event identity mismatch')
    if event.get('action') not in ACTIONS or (event.get('number', number) != number):
        raise Reject('invalid restored event action')
    return event

def write_outputs(event):
    encoded = json.dumps(event, ensure_ascii=True, separators=(',', ':'))
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=os.environ['RUNNER_TEMP'], prefix='pr-event-', suffix='.json', delete=False) as f:
        f.write(encoded)
        path = f.name
    label = event.get('label') or {}
    bootstrap = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'event-bootstrap.cjs')
    outputs = {'eligible': 'true', 'event-json': encoded, 'event-path': path,
               'node-options': '--require=' + json.dumps(bootstrap, ensure_ascii=False),
               'pr-number': str(event['pull_request']['number']), 'action': event['action'],
               'label': label.get('name', '') if isinstance(label, dict) else '',
               'body-without-comments': re.sub(r'<!--.*?-->', '', event['pull_request'].get('body') or '', flags=re.S)}
    write_output_values(outputs)

def write_output_values(outputs):
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
        for key, value in outputs.items():
            delimiter = 'ghadelimiter_' + uuid.uuid4().hex
            while delimiter in value:
                delimiter = 'ghadelimiter_' + uuid.uuid4().hex
            f.write('%s<<%s\n%s\n%s\n' % (key, delimiter, value, delimiter))

def main():
    try:
        repository = os.environ['GITHUB_REPOSITORY']
        restored = os.environ.get('INPUT_EVENT_JSON', '')
        if restored:
            if len(restored.encode('utf-8')) > 4 * 1024 * 1024:
                raise Reject('restored event too large')
            event = validate_restore(parse_json(restored), repository)
        else:
            if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_run':
                raise Reject('unsupported event')
            with open(os.environ['GITHUB_EVENT_PATH'], 'rb') as f:
                payload = parse_json(f.read(4 * 1024 * 1024 + 1))
            event = resolve(API(os.environ['INPUT_GITHUB_TOKEN'], repository), payload,
                            os.environ.get('INPUT_SOURCE_WORKFLOW', ''))
        write_outputs(event)
    except Reject as exc:
        print('::warning::' + str(exc))
        write_output_values({'eligible': 'false'})
    except (RuntimeError, OSError, KeyError, TypeError) as exc:
        print('::error::Unable to resolve pull request event: ' + type(exc).__name__, file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())

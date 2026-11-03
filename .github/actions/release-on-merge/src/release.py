#!/usr/bin/env python3
"""Calculate and publish a release for a fully fetched Git checkout."""
import json
import os
import re
import subprocess
import sys

VERSION = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
HEADER = re.compile(r"^(feat|fix|refactor)(?:\([^\n()]+\))?(!)?: .+")
BREAKING_HEADER = re.compile(r"^[a-z][a-z0-9-]*(?:\([^\n()]+\))?!: .+")
FOOTER = re.compile(r"^(?:[A-Za-z0-9-]+|BREAKING CHANGE|BREAKING-CHANGE)(?:: | #).+")
BREAKING_FOOTER = re.compile(r"^BREAKING(?: CHANGE|-CHANGE): .+")


def run(*args, allow_404=False):
    result = subprocess.run(args, text=True, capture_output=True, timeout=30, check=False)
    if result.returncode:
        if allow_404 and 'HTTP 404' in result.stderr:
            return None
        raise RuntimeError(f"{' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def git(*args):
    return run('git', *args)


def api(path, *args, allow_404=False):
    value = run('gh', 'api', path, *args, allow_404=allow_404)
    return None if value is None else json.loads(value)


def parse(version):
    match = VERSION.fullmatch(version)
    return tuple(map(int, match.groups())) if match else None


def impact(message):
    lines = message.splitlines()
    header = lines[0] if lines else ''
    paragraphs = re.split(r'\n\s*\n', message.strip())
    footer = paragraphs[-1].splitlines() if len(paragraphs) > 1 else []
    is_footer = bool(footer) and bool(FOOTER.match(footer[0])) and all(
        FOOTER.match(line) or line.startswith((' ', '\t')) for line in footer
    )
    if BREAKING_HEADER.match(header) or (is_footer and any(BREAKING_FOOTER.match(line) for line in footer)):
        return 3
    match = HEADER.match(header)
    return {'feat': 2, 'fix': 1, 'refactor': 1}.get(match.group(1), 0) if match else 0


def remote_tag(repo, tag):
    ref = api(f'repos/{repo}/git/ref/tags/{tag}', allow_404=True)
    if ref is None:
        return None
    obj = ref['object']
    for _ in range(8):
        if obj['type'] == 'commit':
            return obj['sha']
        if obj['type'] != 'tag':
            raise RuntimeError(f'{tag} does not resolve to a commit')
        obj = api(f"repos/{repo}/git/tags/{obj['sha']}")['object']
    raise RuntimeError(f'{tag} has too many nested annotated tags')


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    target = git('rev-parse', '--verify', os.environ['INPUT_TARGET_SHA'] + '^{commit}')
    if git('rev-parse', '--is-shallow-repository') != 'false':
        raise RuntimeError('full history and tags are required; checkout with fetch-depth: 0')
    initial = parse(os.environ['INPUT_INITIAL_VERSION'])
    if initial is None:
        raise RuntimeError('initial-version must be a stable vMAJOR.MINOR.PATCH')
    tags = []
    for tag in git('tag', '--merged', target, '--list', 'v*').splitlines():
        version = parse(tag)
        if version is not None:
            tags.append((version, tag, git('rev-list', '-n', '1', tag)))
    tags.sort(reverse=True)
    latest = tags[0] if tags else None
    if latest and latest[2] == target:
        tag = latest[1]
        if remote_tag(repo, tag) != target:
            raise RuntimeError(f'remote tag {tag} does not point at target')
        release = api(f'repos/{repo}/releases/tags/{tag}', allow_404=True)
        if release is not None:
            if release.get('draft') or release.get('prerelease'):
                raise RuntimeError(f'{tag} exists as a draft or prerelease')
            return tag, target, 'true'
        # A tag can remain after a failed release creation. Complete it below.
        return publish(repo, tag, target, existing=True)
    base = latest[0] if latest else initial
    revision_range = f'{latest[1]}..{target}' if latest else target
    commits = git('rev-list', '--first-parent', revision_range).splitlines()
    bump = max((impact(git('show', '-s', '--format=%B', sha)) for sha in commits), default=0)
    if not bump:
        return '', target, 'false'
    major, minor, patch = base
    if bump == 3 and major:
        major, minor, patch = major + 1, 0, 0
    elif bump >= 2:
        minor, patch = minor + 1, 0
    else:
        patch += 1
    tag = f'v{major}.{minor}.{patch}'
    return publish(repo, tag, target)


def publish(repo, tag, target, existing=False):
    remote = remote_tag(repo, tag)
    if remote is not None and remote != target:
        raise RuntimeError(f'remote tag {tag} points to a different commit')
    if remote is not None and not existing:
        raise RuntimeError(f'remote tag {tag} already exists; refresh tags before retrying')
    if remote is None:
        if existing:
            raise RuntimeError(f'remote tag {tag} disappeared')
        api(f'repos/{repo}/git/refs', '-X', 'POST', '-f', f'ref=refs/tags/{tag}', '-f', f'sha={target}')
    if remote_tag(repo, tag) != target:
        raise RuntimeError(f'remote tag {tag} changed before publication')
    run('gh', 'release', 'create', tag, '--repo', repo, '--verify-tag', '--title', tag, '--generate-notes')
    return tag, target, 'true'


if __name__ == '__main__':
    try:
        version, revision, released = main()
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
            output.write(f'version={version}\nrevision={revision}\nreleased={released}\n')
    except (RuntimeError, subprocess.TimeoutExpired, KeyError, ValueError, json.JSONDecodeError) as error:
        print(f'::error::{error}', file=sys.stderr)
        sys.exit(1)

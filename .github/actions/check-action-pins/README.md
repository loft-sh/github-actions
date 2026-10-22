# Check action pins

Check workflow and composite action references under a repository's `.github`
directory. Third-party actions and reusable workflows must use a full commit
SHA. References owned by `loft-sh` may use rolling tags or branches. Local action
paths are allowed. Docker references use zizmor's hash-pin policy.

The check runs zizmor 1.30.1 offline, with this action's policy. It ignores caller
zizmor settings and suppression comments. Only `unpinned-uses` findings block;
scanner failures and invalid workflow or action YAML also fail the check.
README text and shell script text are not action references.

## Usage

The intended release tag is `check-action-pins/v1`. Publish that tag after review
before adding this example to a caller. Then enable the job as a required check
in each opted-in repository. No org-wide policy or branch protection is changed
by this action.

```yaml
name: Check action pins
on: pull_request
permissions: {}
jobs:
  action-pins:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/check-action-pins@check-action-pins/v1
```

Fork pull requests need only `contents: read`. The scanner reads repository files;
it does not run their scripts. Do not switch to `pull_request_target` to run this
check. For a required check, avoid workflow path filters that can leave it pending.

## Runner requirements

Use a Linux or macOS runner with Python 3 and `venv`/`pip`. If zizmor 1.30.1 is
already on PATH, it is reused. Otherwise the action installs the exact version
from PyPI in a temporary virtual environment and deletes it after the check.
Installation needs access to `pypi.org` and `files.pythonhosted.org`; scanning
needs no network access or secrets. The caller's PATH and PYTHONPATH stay unchanged.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

| INPUT |  TYPE  | REQUIRED | DEFAULT |                                          DESCRIPTION                                           |
|-------|--------|----------|---------|------------------------------------------------------------------------------------------------|
| path  | string |  false   |  `"."`  | Repository directory to scan; workflows and <br>action definitions under .github are checked.  |

<!-- AUTO-DOC-INPUT:END -->

## Tests

Run `make test-check-action-pins`. Tests create workflow fixtures in temporary
directories and exercise the real pinned scanner as well as failure handling.
The test workflow also invokes the local composite against this repository.

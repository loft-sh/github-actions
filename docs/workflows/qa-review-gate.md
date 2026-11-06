# QA review gate

Reusable workflow that turns the review panel's QA verdict into the `qa-review`
check-run, handles the `/qa-review override <reason>` and `/qa-review human`
comments, and after the e2e workflow finishes publishes `qa-review-ci` (red when a
spec the PR adds did not run or pass). Wraps the composite action of the same name, adding a sparse checkout
of this repo and the mode selection from the event name. The caller filters the
events in its job `if:` so most reviews and comments spin no runner.

Caller (vcluster-pro, loft-enterprise):

```yaml
name: QA review gate

on:
  pull_request_review:
    types: [submitted]
  issue_comment:
    types: [created]
  workflow_run:
    workflows: ['vCluster Pro E2E CI (e2e)']
    types: [completed]

permissions: {}

jobs:
  gate:
    if: >-
      (github.event_name == 'pull_request_review' && github.event.review.user.login == 'loft-bot') ||
      (github.event_name == 'issue_comment' && github.event.issue.pull_request && startsWith(github.event.comment.body, '/qa-review')) ||
      (github.event_name == 'workflow_run' && github.event.workflow_run.event == 'pull_request')
    permissions:
      checks: write
      pull-requests: write
      contents: read
      actions: read
    uses: loft-sh/github-actions/.github/workflows/qa-review-gate.yaml@qa-review-gate/v1 # zizmor: ignore[unpinned-uses] -- internal loft-sh workflow, pinned by its own rolling tag by policy
    with:
      qa-logins: 'adriankabala,sowmyav27,anvesh-loft'
```

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT    |  TYPE  | REQUIRED |      DEFAULT       |                                 DESCRIPTION                                 |
|-------------|--------|----------|--------------------|-----------------------------------------------------------------------------|
| check-name  | string |  false   |   `"qa-review"`    |                      Name of the check-run to create.                       |
| panel-login | string |  false   |    `"loft-bot"`    |                     Login that posts the panel review.                      |
|  qa-logins  | string |   true   |                    |       Comma-separated logins allowed to run /qa-review <br>override.        |
|   qa-team   | string |  false   | `"loft-sh/eng-qa"` | org/slug of the team asked for <br>a review when a person must <br>decide.  |

<!-- AUTO-DOC-INPUT:END -->

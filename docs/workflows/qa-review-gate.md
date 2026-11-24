# QA review gate

Reusable workflow that turns the review panel's QA verdict into the `qa-review`
check-run, opens `qa-test-run` next to it (green when the PR adds no e2e spec,
waiting otherwise), handles the `/qa-review override [<reason>]` (tech leads, staff engineers, QA) and
`/qa-review human` comments, passes trusted bot PRs (backports, flake fixer) on the
head the bot opened, and after the e2e workflow finishes completes `qa-test-run`
(red when a spec the PR adds did not run or pass). A `/test-e2e` run is a `workflow_dispatch` on the
PR's head branch, so the gate finds the PR through the run's head commit. Wraps the
composite action of the same name, adding a sparse checkout of this repo at the
revision the caller's tag resolved to and the mode selection from the event name. The
caller filters the events in its job `if:` so most reviews and comments spin no runner.

Caller (vcluster-pro, loft-enterprise):

```yaml
name: QA review gate

on:
  pull_request:
    types: [opened]
  pull_request_review:
    types: [submitted]
  issue_comment:  # zizmor: ignore[dangerous-triggers]
    types: [created]
  workflow_run:  # zizmor: ignore[dangerous-triggers]
    workflows: ['vCluster Pro E2E CI (e2e)', 'vCluster OSS E2E CI (Ginkgo)']  # loft-enterprise: its one e2e workflow
    types: [completed]

permissions: {}

jobs:
  gate:
    if: >-
      (github.event_name == 'pull_request' && ((github.event.pull_request.user.login == 'loft-bot' && startsWith(github.event.pull_request.head.ref, 'backport/')) || (github.event.pull_request.user.login == 'vcluster-qa-bot[bot]' && startsWith(github.event.pull_request.head.ref, 'flake-fixer/')))) ||
      (github.event_name == 'pull_request_review' && github.event.review.user.login == 'loft-bot') ||
      (github.event_name == 'issue_comment' && github.event.issue.pull_request && startsWith(github.event.comment.body, '/qa-review')) ||
      (github.event_name == 'workflow_run' && contains(fromJSON('["pull_request", "workflow_dispatch"]'), github.event.workflow_run.event))
    permissions:
      checks: write
      pull-requests: write
      contents: read
      actions: read
    uses: loft-sh/github-actions/.github/workflows/qa-review-gate.yaml@qa-review-gate/v1 # zizmor: ignore[unpinned-uses] -- internal loft-sh workflow, pinned by its own rolling tag by policy
    with:
      report-trees: 'ginkgo-report=,oss-ginkgo-report=staging/github.com/loft-sh/vcluster/'  # vcluster-pro only
    secrets:
      org-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |                                      DEFAULT                                       |                                                                                                DESCRIPTION                                                                                                 |
|-----------------|--------|----------|------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     bot-prs     | string |  false   |              `"loft-bot:backport/,vcluster-qa-bot[bot]:flake-fixer/"`              |                                           Comma-separated login:branch-prefix pairs whose PRs pass <br>both check-runs on every head the <br>bot itself pushed.                                            |
|   check-name    | string |  false   |                                   `"qa-review"`                                    |                                                                                       Name of the verdict check-run.                                                                                       |
| override-logins | string |  false   |                                                                                    |                                                         Comma-separated logins allowed to run /qa-review <br>override, on top of override-teams.                                                           |
| override-teams  | string |  false   |       `"loft-sh/eng-tech-leads,loft-sh/eng-staff-engineers,loft-sh/eng-qa"`        |                                      Comma-separated org/slug teams whose members may <br>run /qa-review override. Membership is read <br>with the org-token secret.                                       |
|   panel-login   | string |  false   |                                    `"loft-bot"`                                    |                                                                                     Login that posts the panel review.                                                                                     |
|    pr-number    | string |  false   |                                                                                    |        Sweep: grade this one PR under <br>its head queue (set by the sweep itself, one run per PR). Empty on <br>the manual run: list the open <br>PRs lacking a check and start <br>a run per PR.         |
|    qa-paths     | string |  false   | `"e2e*/**,staging/github.com/loft-sh/vcluster/e2e/**,.github/workflows/e2e*.yaml"` |                   Comma-separated glob patterns of the QA-owned <br>paths the review panel runs on. <br>A PR that touches none of <br>them passes both check-runs as out <br>of scope.                     |
|     qa-team     | string |  false   |                                 `"loft-sh/eng-qa"`                                 |                                                                     org/slug of the team asked for <br>a review on /qa-review human.                                                                       |
|  report-trees   | string |  false   |                                 `"ginkgo-report="`                                 | Comma-separated artifact=path-prefix pairs: which Ginkgo report <br>artifact covers which source tree. One <br>tree by default; vcluster-pro adds oss-ginkgo-report=staging/github.com/loft-sh/vcluster/.  |
| test-check-name | string |  false   |                                  `"qa-test-run"`                                   |                                                             Name of the check-run that says <br>whether the new e2e specs ran <br>and passed.                                                              |

<!-- AUTO-DOC-INPUT:END -->

# Resolve merged pull requests

Resolve merged pull requests for a default-branch push or a completed read-only pull request signal workflow. The action fetches authoritative PR data from GitHub and only returns closed, merged PRs targeting the default branch. Fork PRs are included after merge.

For a push, the action walks every commit in the before/after range and finds associated PRs whose merge SHA is in that range. A forced push, deleted branch, or new branch with a zero before SHA is skipped. Comparison and associated PR pagination are bounded to 1,000 entries each; incomplete results fail the run. Commits with no associated PR are retried twice as one batch, after 2 and 4 seconds, because GitHub can list a merge commit's PR shortly after the push. Commits still without a PR, such as direct or bot pushes, do not stop the run: the PRs found in the same push are still returned, and a warning lists those commits after the outputs are written. If a listed commit merged a PR, remove and re-add its `backport-to-` label to start the backport through the signal.

For `workflow_run`, the action verifies the run ID, attempt, status, conclusion, source workflow identity, repository, event, head branch and SHA against the API. It uses PR associations from the run or, when empty, from the commit API. A re-fetched PR must match the signal head branch and either its head SHA or merge SHA; its merge commit must be an ancestor of the default branch. No signal artifact is read. Since a signal workflow's code can come from a PR, it must be read-only and carry no secrets. Its output is never treated as authoritative.

The action returns compact identity envelopes in `events-json`, at most 256, for a matrix. When exactly one PR is eligible, `event-json` also contains current `backport-to-` labels. The full re-fetched event is written only to a runner-local file, which can be supplied through the `NODE_OPTIONS` and `RESOLVED_PR_EVENT_PATH` outputs for Node actions. The aggregate job outputs are capped below GitHub's job output limit. The consumer must restore each envelope with this action before using it; restoration verifies its identity and merge SHA, checks that the merge is an ancestor of the default branch, and fetches current labels. On push, restoration also checks that the merge belongs to the original push range. It re-fetches only the selected PR and uses a constant number of API requests without walking the push range again. Both selector and consumer require `contents: read` and `pull-requests: read`; the signal consumer also needs `actions: read`. All consumers must run from the default branch.

The default-branch push covers merges. Use the signal for labels added after merge; omitting `closed` avoids a second backport run for the same merge.

Example signal workflow, `.github/workflows/pull-request-events.yaml`:

```yaml
name: Pull request events
on:
  pull_request:
    types: [labeled]
permissions: {}
jobs:
  signal:
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - run: ':'
```

Example selector and fanout for a repository whose default branch is `main`:

```yaml
name: Backport on merge
on:
  push:
    branches: [main]
  workflow_run:
    workflows: [Pull request events]
    types: [completed]
permissions: {}
jobs:
  select:
    runs-on: ubuntu-latest
    permissions:
      actions: read
      contents: read
      pull-requests: read
    outputs:
      events: ${{ steps.resolve.outputs.events-json }}
    steps:
      - id: resolve
        uses: loft-sh/github-actions/.github/actions/resolve-pr-event@resolve-pr-event/v1
        with:
          source-workflow: .github/workflows/pull-request-events.yaml
  backport:
    needs: select
    if: needs.select.outputs.events != '[]' && needs.select.outputs.events != ''
    strategy:
      matrix:
        event: ${{ fromJSON(needs.select.outputs.events) }}
    permissions:
      actions: read
      contents: read
      pull-requests: read
    uses: loft-sh/github-actions/.github/workflows/backport.yaml@backport/v2
    with:
      pr-event: ${{ toJSON(matrix.event) }}
      source-workflow: .github/workflows/pull-request-events.yaml
    secrets:
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

The example uses a published action and does not check out PR code. Coordinate publication of the action and reusable workflow tags with caller rollout.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |                    DEFAULT                     |                                      DESCRIPTION                                       |
|-----------------|--------|----------|------------------------------------------------|----------------------------------------------------------------------------------------|
|   event-json    | string |  false   |                                                |            Trusted payload passed between jobs through <br>workflow_call.              |
|  github-token   | string |  false   |            `"${{ github.token }}"`             | Token with contents and pull requests <br>read access; actions read for workflow_run.  |
| source-workflow | string |  false   | `".github/workflows/pull-request-events.yaml"` |               Expected read-only pull request signal workflow <br>path.                |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT    |  TYPE  |                                  DESCRIPTION                                  |
|--------------|--------|-------------------------------------------------------------------------------|
|    action    | string |                             Pull request action.                              |
|   eligible   | string |                    Whether a validated event is available.                    |
|  event-json  | string | Compact PR identity and backport labels <br>when exactly one PR is eligible.  |
|  event-path  | string |          Temporary synthetic event file for RESOLVED_PR_EVENT_PATH.           |
| events-json  | string |         Array of compact PR identity envelopes <br>for a job matrix.          |
| node-options | string | NODE_OPTIONS preload for Node actions that <br>consume the synthetic event.   |
|  pr-number   | string |                             Pull request number.                              |

<!-- AUTO-DOC-OUTPUT:END -->

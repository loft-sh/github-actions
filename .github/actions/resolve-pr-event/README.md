# Resolve pull request event

Resolve a completed `workflow_run` from the `pull_request_target` relay at
`.github/workflows/pull-request-events.yaml` into a synthetic event containing
the current pull request and repository from GitHub.
The caller supplies `source-workflow` and a token with `actions: read`,
`contents: read`, and `pull-requests: read`. The relay must upload an artifact
named `pull-request-event-<run_attempt>`, containing only `event.json` with
`number`, `action`, and `label`. The label is an empty string unless the action
is `labeled`.

Check `eligible == 'true'` before consuming outputs. Pass `event-json` through a
trusted workflow input to restore it in a later job. For each Node action that
needs the synthetic event, set `NODE_OPTIONS` to `node-options` and
`RESOLVED_PR_EVENT_PATH` to `event-path` in its step environment. The preload
validates the file and sets the Node process event context before the action
starts. The temporary file contains the current PR payload; avoid printing it. An unavailable artifact,
stale label, or failed provenance check produces a warning and an
ineligible result. API errors fail the action.

Validation uses the exact workflow ID and path in the base repository and
GitHub's `pull_request_target` guarantee that the workflow comes from the base
repository default branch. The run head SHA belongs to the PR and
is not used as the workflow source SHA. The relay may only capture and upload metadata. It must not check out or execute
PR code or use business secrets.
See [GitHub's pull_request_target security guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).

## Event policy and rollout

The relay still uses `pull_request_target` to preserve events from conflicted
PRs. It needs an explicit Actions event policy on each public caller repository.
Scope the policy to `.github/workflows/pull-request-events.yaml` and allow only
`pull_request_target`. The privileged consumers use `workflow_run` outside this allowance.
An administrator creates the policy separately from merging these changes.

Merge the shared action and backport workflow changes before the caller PRs.
Publish `resolve-pr-event/v1` and update `backport/v1` to that merged commit before
activating callers. Verify the tags before merging callers. Test a branch PR, a
fork PR, a conflicted fork PR, a merged backport, and each Linear integration.
Local tests and lint do not prove these live events.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |         DEFAULT         |                            DESCRIPTION                            |
|-----------------|--------|----------|-------------------------|-------------------------------------------------------------------|
|   event-json    | string |  false   |                         |  Trusted payload passed between jobs through <br>workflow_call.   |
|  github-token   | string |  false   | `"${{ github.token }}"` | Token with actions, contents, and pull <br>requests read access.  |
| source-workflow | string |  false   |                         | Expected relay path, .github/workflows/pull-request-events.yaml.  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|        OUTPUT         |  TYPE  |                                 DESCRIPTION                                  |
|-----------------------|--------|------------------------------------------------------------------------------|
|        action         | string |                             Pull request action.                             |
| body-without-comments | string |     PR body with HTML comments removed, <br>for follow-up descriptions.      |
|       eligible        | string |                   Whether a validated event is available.                    |
|      event-json       | string |            Synthetic event JSON for passing to <br>another job.              |
|      event-path       | string |          Temporary synthetic event file for RESOLVED_PR_EVENT_PATH.          |
|         label         | string |                    Current label name for labeled events.                    |
|     node-options      | string | NODE_OPTIONS preload for Node actions that <br>consume the synthetic event.  |
|       pr-number       | string |                             Pull request number.                             |

<!-- AUTO-DOC-OUTPUT:END -->

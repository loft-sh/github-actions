# Retry approved PR CI

Retry failed jobs in an explicitly allowed PR workflow, at most three times. The
action is disabled by default and dry run is on by default. It never approves,
merges, changes code, or starts an AI session. No repository is enrolled by this PR.

The pilot leaves review timing with the team. It only helps an already approved
commit recover from a failed run. A red check stays red until its own jobs pass.
The PR author owns diagnosis when retries fail.

## Policy

All of these must hold before a retry:

- The completed run failed on a `pull_request` event in this repository. Forks,
  drafts, closed PRs, push runs and ambiguous run/PR associations are skipped.
- The numeric workflow ID is in the caller's explicit allowlist. Enroll test
  workflows only, after reviewing their side effects and common failure modes.
  Do not enroll deployment, credential, or permission-failure workflows.
- The PR head equals the failed run's SHA. GitHub's review decision is `APPROVED`,
  and a human writer other than the author approved that exact commit. Outstanding
  change requests, dismissed approvals and incomplete review reads block retries.
- The run ID is the latest for that PR, workflow and SHA. All pages are checked,
  up to 1,000 runs; larger histories and missing metadata are skipped.
- The attempt equals the completed event's attempt. Manual reruns consume the
  same budget: attempt 1 can request retry 1; attempt 4 has used all three retries.

The action reads this policy again before the write. Dry run performs the same
reads. It calls only `rerun-failed-jobs`, once; it never retries an uncertain POST.
API errors leave the decision `error`, with a link and remedy in the job summary.
This advisory step exits green; it does not replace or hide the failed CI checks.

## Caller

Requires `gh` and Python 3 on the runner. Use a trusted default-branch
`workflow_run` handler without checking out or executing PR code. Never consume
artifacts or scripts supplied by the failed workflow in this privileged job.

Example for a repository owner to adapt after the pilot is approved and
`retry-approved-pr-ci/v1` is released. The tag is not published by this PR.
Replace the workflow name and numeric ID with a reviewed test workflow.

```yaml
name: Retry approved PR CI
on:
  workflow_run:
    workflows: [PR tests]
    types: [completed]

permissions: {}

concurrency:
  group: approved-ci-retry-${{ github.event.workflow_run.id }}
  cancel-in-progress: false

jobs:
  retry:
    if: github.event.workflow_run.event == 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      actions: write
      contents: read
      pull-requests: read
    steps:
      - uses: loft-sh/github-actions/.github/actions/retry-approved-pr-ci@retry-approved-pr-ci/v1
        id: retry
        with:
          enabled: 'true'
          dry-run: 'true'
          workflow-ids: '123456'
          run-id: ${{ github.event.workflow_run.id }}
          run-attempt: ${{ github.event.workflow_run.run_attempt }}
          github-token: ${{ github.token }}
```

Keep exactly one handler and the concurrency group above per repository/run.
This serializes duplicate events. The attempt check then skips an older event
after a rerun starts. GitHub does not offer an atomic head/approval condition on
the rerun endpoint: a change after the final read can still start work on the old
SHA. This action cannot merge that work and never transfers approval to a new SHA.

The default token may suppress follow-on workflow events from its writes. Before
live enrollment, verify that reruns produce the next completed `workflow_run`
event with the chosen token. Without that evidence, only a single automatic
retry is proven. If an App token is needed, review its scope and credential path
separately; do not reuse a merge-bypass identity.

## Diagnosis handoff

`outcome=exhausted` stops all retry requests and emits `diagnosis`, a JSON string:

```json
{"version":1,"repository":"owner/repo","pr_number":42,"head_sha":"<40 hex characters>","workflow_id":55,"run_id":123,"run_attempt":4,"run_url":"https://github.com/owner/repo/actions/runs/123","reason":"retry_budget_exhausted"}
```

This is failure context for a human or a future diagnosis adapter, not the QA
bot's existing input schema. It contains no logs, credentials or PR prose.
Consumers must fetch evidence for this exact SHA, preserve the author's ownership,
and recheck current state before acting. There is no automatic dispatch, issue
creation or code-fix permission in this action.

The QA diagnosis path consumes groups of failed nightly specs and history.
Arbitrary PR workflows need an adapter to that input contract. Verify its input
producer, deployment and supported failure types before connecting it. Any fix
must get its own human review.

## Pilot acceptance

1. Offline tests cover retries, budget exhaustion, duplicate events, stale heads
   and approvals, forks, incomplete API data, pagination, and dry-run parity.
2. A repository owner selects test-only workflow IDs and inspects dry-run job
   summaries before enabling writes. `enabled=false` turns the action off.
3. A controlled failing PR proves one retry, follow-on event delivery, and the
   full three-retry stop with the selected token. No live proof is claimed here.
4. A new commit or withdrawn approval stops retries. Exhaustion leaves the CI red
   and produces the diagnosis handoff. The author diagnoses or asks QA for help.
5. Automatic merging stays disabled. Required-check and merge policy need a
   separate explicit decision, including the current head and branch protections.

## Workflow and failure table

| Stage | Trigger and reads | Mutation | Emits / skip remedy | Coverage |
|---|---|---|---|---|
| Select | Completed event, run metadata, workflow allowlist | None | Skip unsupported run; select a test workflow | New policy; existing bot approval stays unchanged |
| Review | Current PR SHA, effective writer reviews, review decision | None | Skip changed head or review; author obtains review of current commit | Existing GitHub review state; new retry gate |
| Budget | Event attempt, current attempt, paginated runs | None | Exhausted handoff or skip old event/run; author diagnoses | New bounded retry policy; GitHub persists attempts |
| Revalidate | Repeat run, review, and latest-run reads | None in dry run | `would_retry` or skip changed state | New guard; API race above remains |
| Retry | All gates passed | New: one failed-jobs rerun request | `retried`; uncertain response is `error`, inspect run before any retry | GitHub executes original workflow; no local PR execution |
| Escalate | Budget exhausted | None | JSON diagnosis and run link; human owns next action | New output; QA adapter and deployment are unverified |

Each stage emits a fixed `outcome`/`reason` vocabulary to stdout and action outputs;
the job summary links the failed run. Exhaustion and errors name the diagnosis
remedy. No service metrics, Slack alert or separate dashboard is introduced.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT     |  TYPE  | REQUIRED |  DEFAULT  |                                        DESCRIPTION                                         |
|--------------|--------|----------|-----------|--------------------------------------------------------------------------------------------|
|   dry-run    | string |  false   | `"true"`  |             Perform the same policy reads but <br>suppress the retry request               |
|   enabled    | string |  false   | `"false"` |                      Explicit opt-in to policy reads and <br>retries                       |
| github-token | string |   true   |           | Token with Actions write, Contents read <br>and Pull requests read in this <br>repository  |
| max-retries  | string |  false   |   `"3"`   |   Maximum reruns per workflow run, including <br>manual reruns; integer from 0 to <br>3    |
| run-attempt  | string |   true   |           |            Attempt from that event; stale or <br>duplicate events are skipped              |
|    run-id    | string |   true   |           |                  Workflow run ID from a completed <br>workflow_run event                   |
| workflow-ids | string |   true   |           |     Comma-separated numeric workflow IDs approved for <br>retries in this repository       |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT    |  TYPE  |                                              DESCRIPTION                                               |
|--------------|--------|--------------------------------------------------------------------------------------------------------|
|  diagnosis   | string | JSON handoff with verified repository, PR, <br>SHA and run identifiers when retries <br>are exhausted  |
|   head_sha   | string |                  Verified PR head SHA, empty when <br>eligibility is not established                   |
|   outcome    | string |                    disabled, skipped, would_retry, retried, exhausted or <br>error                     |
|    reason    | string |                                  Fixed policy reason for the decision                                  |
| retries_used | string |                  Observed reruns before this invocation, including <br>manual reruns                   |
|   run_url    | string |                                    Workflow run for human diagnosis                                    |

<!-- AUTO-DOC-OUTPUT:END -->

## Tests

`make test-retry-approved-pr-ci` runs offline pytest with mocked GitHub responses.
The test workflow also runs on changes to its own definition. `make lint` checks
workflow syntax and security, and `make generate-docs` updates the tables above.

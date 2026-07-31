# Wait for release

Blocks until a GitHub Release for a given version exists in a given repository.

For pipelines with a cross-repo ordering dependency: one repo's build uploads
assets into a release that another repo's build creates, and the consumer has no
control over when the producer gets there.

## Why not just poll for the release

Because presence polling cannot tell **"the producer is still building"** apart
from **"the producer died half an hour ago"**. Both look identical, since in
both cases the release simply isn't there. So a presence-only wait spends its
entire timeout on a precondition that can never be met, then fails with a
message that says nothing about why.

Worse, retrying the consumer is then futile by construction: the only thing that
can fix it is re-running the *producer*. A waiter that cannot say so sends people
into re-run loops. This was DEVOPS-1234, where a release build was re-run twice
at 24 minutes a go against an upstream release that had already failed.

Set `workflow` to the producer's workflow file and the wait becomes
status-aware. A run that already concluded `failure`, `cancelled`, `timed_out`
or `startup_failure` fails the wait immediately, naming the run and the recovery
order.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED | DEFAULT |                                                                                                                  DESCRIPTION                                                                                                                  |
|------------------|--------|----------|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   github-token   | string |   true   |         |                                                                              Token with contents:read on `repo`, plus <br>actions:read when `workflow` is set.                                                                                |
| interval-seconds | string |  false   | `"15"`  |                                                                                                        Seconds to sleep between polls.                                                                                                        |
| max-api-failures | string |  false   |  `"5"`  |                                                                  Consecutive GitHub API failures tolerated before <br>failing. A single blip must never <br>fail a release.                                                                   |
|   max-attempts   | string |  false   | `"120"` |                                                                            Polls before giving up. The wall-clock <br>ceiling is max-attempts x interval-seconds.                                                                             |
|       repo       | string |   true   |         |                                                                                Repository publishing the release, as owner/name <br>(e.g. loft-sh/vcluster).                                                                                  |
|     version      | string |   true   |         |                                                                                                 Release tag to wait for (e.g. v0.36.1-rc.2).                                                                                                  |
|     workflow     | string |  false   |         | Workflow file in `repo` that produces <br>the release (e.g. release.yaml). When set, a <br>producer run that has already failed <br>fails this wait immediately rather than <br>waiting out the timeout. Omit for <br>a plain presence poll.  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT     |  TYPE  |                             DESCRIPTION                             |
|----------------|--------|---------------------------------------------------------------------|
|  release-url   | string |               URL of the release that was <br>found.                |
| waited-seconds | string | Approximate seconds spent waiting before the <br>release appeared.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

Plain presence poll, waiting up to 30 minutes (120 x 15s):

```yaml
- uses: loft-sh/github-actions/.github/actions/wait-for-release@wait-for-release/v1
  with:
    repo: loft-sh/vcluster
    version: v0.36.1-rc.2
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

Status-aware, failing fast if the producing workflow has already failed:

```yaml
- uses: loft-sh/github-actions/.github/actions/wait-for-release@wait-for-release/v1
  with:
    repo: loft-sh/vcluster
    version: ${{ steps.get_version.outputs.release_version }}
    workflow: release.yaml
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

Set the ceiling from the producer's real build time. `max-attempts x
interval-seconds` should comfortably exceed it, because a budget that merely
*usually* covers the producer is a latent failure on every run.

## Behaviour

| Observed | Action |
|----------|--------|
| Release exists | Succeed, emit `release-url` |
| Release absent (clean 404) | Keep waiting |
| Producer concluded `failure` / `cancelled` / `timed_out` / `startup_failure` | **Fail immediately** with the run URL and recovery order |
| Producer still `queued` / `in_progress` | Keep waiting |
| Producer `success` but release absent | Keep waiting one poll for read lag, then fail as inconsistent |
| Producer run not found | Keep waiting, since dispatch can lag |
| Producer lookup errored | Keep waiting, since the release is the authority rather than the producer's health |
| Release lookup errored | Keep waiting, up to `max-api-failures` consecutive |
| Attempts exhausted | Fail with the elapsed budget, plus the cumulative API-failure count when any occurred |

Two rules drive the table:

**The three lookup outcomes stay strictly distinct:** present, cleanly absent,
and API error. Collapsing them is how a waiter goes wrong. An API error read as
"absent" waits out the timeout on a release that is actually there, and read as
"present" it lets the caller upload into a release that does not exist.

**The release is the authority; the producer's health is only a hint.** A missing
or unreadable producer run never fails the wait, because dispatch lag and API
blips are normal. Only a run that has definitively finished unsuccessfully is
grounds to stop, since at that point no amount of waiting can help.

`max-api-failures` counts *consecutive* failures, so one blip can never fail a
release. The trade-off is that a partial outage which interleaves errors with
real 404s, intermittent rate-limiting for instance, keeps resetting the counter
and never trips the breaker. That fails in the safe direction, the wait simply
times out, but a bare timeout would read as "the producer was slow" when the
truth is "we could barely see the API". So the timeout also reports the
cumulative failure count whenever any occurred, which keeps the two
distinguishable in the log.

## Permissions

`contents: read` on `repo`, plus `actions: read` when `workflow` is set. For a
cross-repo wait the default `GITHUB_TOKEN` is not enough, being scoped to the
calling repo, so pass a token with read access to the target repo.

## Tests

```bash
make test-wait-for-release
```

20 bats tests, needing no token and no network: a configurable `gh` stub on
`PATH` covers each row of the table above, and `WAIT_INTERVAL_SECONDS=0` keeps
the suite instant while still exercising the real attempt accounting.

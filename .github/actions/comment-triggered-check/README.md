# Comment-triggered check

Turns a pull request comment such as `/test snapshots` into a check-run on the
pull request's head commit, and completes that check-run when the caller's work
finishes.

The action never runs tests. It decides whether a command should run, resolves
the pull request identity that the event does not carry, and owns the check-run
lifecycle. What runs in between is entirely the caller's business, which is why
this lives here and the e2e half lives in the product repo.

## Why the check-run is created through the API

An `issue_comment` run has `GITHUB_SHA` set to the last commit on the default
branch and `GITHUB_REF` set to the default branch. Every check-run GitHub
publishes automatically for such a workflow therefore attaches to the default
branch and is invisible on the pull request. Creating one against the resolved
head SHA is the only way to get a row the reviewer can see, and it is a
consequence of the trigger rather than a stylistic choice.

The same fact is why `head-sha` and `base-ref` are outputs. Nothing downstream
can infer them: a plain `actions/checkout` in a job of this workflow takes the
default branch, and `github.base_ref` is empty.

## Security boundary: same-repository only

`issue_comment` is a privileged trigger. It runs from the default branch of the
base repository with that repository's secrets and a write token, so a workflow
that checks out and executes pull request code from a fork hands both to whoever
opened the fork. GitHub's guidance is explicit that privileged workflows "must
not explicitly check out untrusted code, including from pull request forks".

So the fork test is a security boundary, not a capability gap, and `start`
performs it before emitting anything a caller would act on. Keep the caller's
checkout gated on `should-run`.

## Who may run it

From `author_association` in the event payload: `OWNER`, `MEMBER` and
`COLLABORATOR` may, anything else may not, and an empty value is a no rather
than a default yes.

Be precise about what that means, because the output is named `should-run` and
could be read as more than it is. An association is not a permission level.
`MEMBER` means organization membership, not access to this repository, and
`COLLABORATOR` says someone was added without saying at what level, so a
read-only collaborator passes. This is deliberately coarser than the
collaborator permission endpoint, which would cost an API call and a token
scope. Because the command is same-repo only, the cost of the coarseness is
runner time rather than access. Swap in the precise check if that stops being
true.

## The two modes

`start` parses the comment, authorizes the commenter, resolves the pull request,
and opens the check-run. Two API calls, and none at all for a comment that is
not a command.

`finish` resolves the terminal outcome and completes it. Give it the check-run
id from `start` and the raw job results; it computes the conclusion so the
matrix lives in a tested script rather than in workflow YAML.

## The outcome matrix fails closed

| Condition | Conclusion |
| --- | --- |
| `report-conclusion` is set and recognised | that value. **The only path to `neutral`** |
| the suite or the build was cancelled | `cancelled` |
| anything else | `failure` |

Two mappings are deliberately absent, and they are the point.

An empty report after the job ran does **not** become `cancelled`. That state
also covers a failed checkout, setup, artifact download or cloud login, and
`cancelled` is not a cheap default: the `auto-approve-bot-prs` action holds a
cancelled check while it waits for a replacement and then refuses approval, so a
mis-mapped `cancelled` stalls auto-approve instead of failing cleanly.

A skipped suite after a successful build does **not** become `neutral`, because
`neutral` is an acceptable verdict and an unexplained skip is not an acceptable
outcome. Report `neutral` only from something that actually inspected the run,
such as a test report saying zero specs matched.

Values outside `success failure neutral cancelled timed_out` are rejected with a
warning and fail closed, so an unexpected value can never read as green.

## Repeated commands are GitHub's job, not this action's

Typing the same command twice should not build twice, but the action does not
deduplicate. Give the caller's suite job a `concurrency` group keyed on the
repository, the pull request and the filter, with `cancel-in-progress: true`.
GitHub then supersedes the older run, and the superseded job still triggers the
caller's `always()` finish job, which closes its check-run as `cancelled`.

This was originally built here instead, and it was a mistake worth recording.
Deduplicating in the action meant listing check-runs, resolving the workflow run
behind each one, and closing the orphans left by lost runners, which needed
three extra API calls, a run id smuggled through `external_id`, a staleness
rule, and a `queue: max` on the calling job to close the check-then-create race
it introduced. Every failure mode in that machinery ended the same way: starting
a duplicate build, the exact thing it existed to prevent. The platform already
does this correctly.

The one thing lost is that a repeat cancels the running suite rather than
replying "already running". That is the same behaviour a new push already gets
on the main pull request gate, so it is at least consistent.

## Permissions

The calling job needs `checks: write` to create and complete the check-run, and
`pull-requests: read` to resolve the head SHA and base ref. That is all: the
commenter's access is read from the event payload, not from an API call.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED |           DEFAULT            |                                                                                                           DESCRIPTION                                                                                                            |
|--------------------|--------|----------|------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| author-association | string |  false   |                              | start mode. How the commenter relates <br>to the repository. Pass the github.event.comment.author_association <br>context. OWNER, MEMBER and COLLABORATOR may <br>run the command; anything else, including <br>empty, may not.  |
|    build-result    | string |  false   |                              |                                                                            finish mode. Result of the build <br>job. Pass the matching needs result.                                                                             |
| check-name-prefix  | string |  false   |           `"e2e"`            |                                                                             start mode. Prefix for the check-run <br>name; the filter is appended.                                                                               |
|    check-run-id    | string |  false   |                              |                                                          finish mode. The id returned by <br>start mode. Empty is not an <br>error; it means no check was <br>opened.                                                            |
|      command       | string |  false   |          `"/test"`           |                                                                               Command word that must open the <br>comment, on its own first line.                                                                                |
|   comment-author   | string |  false   |                              |                                                                    start mode. Login of the commenter. <br>Pass the github.event.comment.user.login context.                                                                     |
|    comment-body    | string |  false   |                              |                                                                          start mode. The comment text. Pass <br>the github.event.comment.body context.                                                                           |
|    details-url     | string |  false   |                              |                                                                                    finish mode. Link target for the <br>completed check-run.                                                                                     |
|    github-token    | string |  false   |   `"${{ github.token }}"`    |                                                                     Token for gh. The calling job <br>must grant checks: write and pull-requests: <br>read.                                                                      |
|        mode        | string |   true   |                              |                                                                                                   Either "start" or "finish".                                                                                                    |
|     pr-number      | string |  false   |                              |                                                                        start mode. Pull request number. Pass <br>the github.event.issue.number context.                                                                          |
|        repo        | string |  false   | `"${{ github.repository }}"` |                                                                                                  Repository in owner/name form.                                                                                                  |
| report-conclusion  | string |  false   |                              |                                         finish mode. What the test run <br>declared about itself, parsed from its <br>report. The only input that can <br>produce a neutral conclusion.                                          |
|       run-id       | string |  false   |                              |                                                                  start mode. Used to build the <br>check-run details link. Pass the github.run_id <br>context.                                                                   |
|     server-url     | string |  false   |    `"https://github.com"`    |                                                           start mode. Base URL used to <br>build the check-run details link. Pass <br>the github.server_url context.                                                             |
|    suite-result    | string |  false   |                              |                                                                            finish mode. Result of the suite <br>job. Pass the matching needs result.                                                                             |
|      summary       | string |  false   |                              |                                                                finish mode. Markdown body for the <br>completed check-run. Defaults to the two <br>job results.                                                                  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT      |  TYPE  |                                                                                                                                                                                                                                  DESCRIPTION                                                                                                                                                                                                                                  |
|-----------------|--------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|      args       | string |                                                                                                                                                                                                           Raw argument string that followed the <br>command word.                                                                                                                                                                                                             |
|    base-ref     | string |                                                                                                                                                                                            Resolved base branch of the pull <br>request. The event does not carry <br>it either.                                                                                                                                                                                              |
|   check-name    | string |                                                                                                                                                                                                       Display name of the check-run, sanitized <br>and length-bounded.                                                                                                                                                                                                        |
|  check-run-id   | string |                                                                                                                                                                                        Id of the opened check-run. Empty <br>when nothing was opened; gate the <br>finish job on it.                                                                                                                                                                                          |
|   conclusion    | string |                                                                                                                                                                                                             finish mode. The conclusion that was <br>published.                                                                                                                                                                                                               |
| concurrency-key | string |                                                                                  Filter reduced to a lowercase slug <br>plus an eight-character digest of the <br>normalized filter, safe to interpolate into <br>a concurrency group. The digest is <br>not decoration: the slug alone drops <br>punctuation, so "a && b" and <br>"a || b" would share a <br>group and cancel each other.                                                                                    |
|     filter      | string |                                                                                                                                                                                         Argument string with whitespace normalized. This <br>is what to pass to the <br>test runner.                                                                                                                                                                                          |
|    head-sha     | string |                                                                                                                                                                                                Resolved head commit of the pull <br>request. The event does not carry <br>it.                                                                                                                                                                                                 |
|     matched     | string |                                                                                                                                                                                                          "true" when the comment opened with <br>the command word.                                                                                                                                                                                                            |
|     reason      | string |                                                                                                                                      Why the command will not run: <br>fork, insufficient-permission, empty-filter, not-a-pull-request, pull-request-closed, pull-request-unreadable, <br>or check-run-not-created. Empty when it will.                                                                                                                                       |
|   should-run    | string | The caller's execution gate. "true" only <br>when a check-run was actually opened, <br>so it is false for a <br>comment that was not a command, <br>an empty filter, a fork, a <br>closed or unreadable pull request, a <br>rejected author_association, and a failed check-run <br>creation. Read reason for which. Note <br>the association test is not a <br>permission check: MEMBER means organization membership, <br>and COLLABORATOR does not say at <br>what level.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
name: Test command

on:
  issue_comment:
    types: [created]

permissions:
  checks: write
  pull-requests: read
  contents: read

jobs:
  prepare:
    # Cheap pre-filter so the job does not start for every comment in the repo.
    if: github.event.issue.pull_request && startsWith(github.event.comment.body, '/test')
    runs-on: ubuntu-latest
    outputs:
      should-run: ${{ steps.cmd.outputs.should-run }}
      filter: ${{ steps.cmd.outputs.filter }}
      head-sha: ${{ steps.cmd.outputs.head-sha }}
      base-ref: ${{ steps.cmd.outputs.base-ref }}
      key: ${{ steps.cmd.outputs.concurrency-key }}
      check-run-id: ${{ steps.cmd.outputs.check-run-id }}
    steps:
      - uses: loft-sh/github-actions/.github/actions/comment-triggered-check@comment-triggered-check/v1
        id: cmd
        with:
          mode: start
          comment-body: ${{ github.event.comment.body }}
          comment-author: ${{ github.event.comment.user.login }}
          author-association: ${{ github.event.comment.author_association }}
          pr-number: ${{ github.event.issue.number }}
          run-id: ${{ github.run_id }}
          server-url: ${{ github.server_url }}

  suite:
    needs: [prepare]
    if: needs.prepare.outputs.should-run == 'true'
    runs-on: ubuntu-latest
    # This is the deduplication. A second identical command supersedes this run,
    # and the finish job below still closes the superseded check-run.
    concurrency:
      group: comment-triggered-check-suite-${{ github.event.issue.number }}-${{ needs.prepare.outputs.key }}
      cancel-in-progress: true
    outputs:
      check-conclusion: ${{ steps.run.outputs.check-conclusion }}
    steps:
      - id: run
        run: echo "... build and test at needs.prepare.outputs.head-sha ..."

  finish:
    needs: [prepare, suite]
    if: always() && needs.prepare.outputs.check-run-id != ''
    runs-on: ubuntu-latest
    steps:
      - uses: loft-sh/github-actions/.github/actions/comment-triggered-check@comment-triggered-check/v1
        with:
          mode: finish
          check-run-id: ${{ needs.prepare.outputs.check-run-id }}
          report-conclusion: ${{ needs.suite.outputs.check-conclusion }}
          suite-result: ${{ needs.suite.result }}
          details-url: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

A caller with a separate build job adds it to `needs` and passes
`build-result: ${{ needs.build.result }}`, which lets a cancelled build be
reported as `cancelled` rather than falling into the catch-all.

The `finish` job needs every job whose result it reads, and it needs the id
guard because `prepare` legitimately opens no check-run for a comment that was
not a command, an unauthorized commenter, or a fork. It must also stay on
`always()`: closing the check when the suite was cancelled is what keeps a
superseded run from leaving one open.

## What happens if `finish` cannot publish

The PATCH is retried a few times, because this is the last chance to close the
check-run and a transient API failure is the likely cause. If every attempt
fails, or the runner is lost before the job runs at all, the check-run stays
`in_progress` and nothing reconciles it. That is an accepted residual risk
rather than an oversight: the alternative was a reconciliation pass on the next
command, and it cost three API calls plus a state machine whose own failure
modes were worse than the problem.

It matters because anything waiting on all of a commit's check-runs, including
`auto-approve-bot-prs`, waits on a stuck one indefinitely.

The recovery path is **"Re-run failed jobs"**, not "Re-run all jobs". The
narrow one re-runs `finish` alone and reuses the check-run id from `prepare`,
whose outputs are preserved; the broad one runs `start` again and opens a
second check-run for the same filter. The error message names the distinction.

## Reporting failures to the author

The action deliberately posts no comments. It emits `reason` and leaves
messaging to the caller, which keeps it usable by repositories that surface
results differently. Pair it with `sticky-pr-comment` when the caller wants a
comment, and key the marker on the filter so concurrent commands do not
overwrite each other's links.

`reason` values: `fork`, `insufficient-permission`, `empty-filter`,
`not-a-pull-request`, `pull-request-closed`, `pull-request-unreadable`,
`check-run-not-created`. Empty when the command will run.

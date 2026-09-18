# Comment-triggered check

Turns a pull request comment such as `/test-e2e snapshots` into a check-run on the
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

The same fact is why `head-sha`, `head-ref`, `base-ref` and `dispatch-ref` are outputs. Nothing
downstream can infer them: a plain `actions/checkout` in a job of this workflow
takes the default branch, and `github.base_ref` is empty. `dispatch-ref` is the
head branch for a same-repository pull request and the trusted base branch for
a fork. It is a branch because `gh workflow run --ref` does not accept a SHA.

## Handing the work to a non-privileged run

Worth doing, and the reason `head-ref` exists. A workflow triggered by
`issue_comment` is privileged, so if it checks out the pull request and then
calls a local action with `uses: ./...`, the *action definition* comes from the
pull request and executes with repository secrets and a write token. CodeQL
flags that as `actions/untrusted-checkout-toctou`, correctly.

For a same-repository pull request, keep this action's jobs free of any checkout
and dispatch the actual work to a `workflow_dispatch` run on the head branch.
That run is not a privileged trigger, and its trust model is the one a normal
pull request run already has.

Pass three things along, not one. The check-run id, so the dispatched workflow
can finish what this one opened, and **both** refs, because they answer
different questions:

| output | what it is for |
| --- | --- |
| `dispatch-ref` | the `--ref` of the dispatch. It selects the head workflow for a same-repository PR and the base workflow for a fork |
| `head-sha` | the commit the check-run was opened on, and the commit the run must actually test |

For a same-repository PR, a push can move the head branch between resolution and
dispatch. The dispatched workflow should therefore take `head-sha` as an input
and refuse to run if `github.sha` no longer matches it.

## Security boundary: forks are opt-in

`issue_comment` is a privileged trigger. It runs from the default branch of the
base repository with that repository's secrets and a write token, so a workflow
that checks out and executes pull request code from a fork hands both to whoever
opened the fork. GitHub's guidance is explicit that privileged workflows "must
not explicitly check out untrusted code, including from pull request forks".

Forks are therefore refused by default. A caller may set `allow-forks: "true"`
only when its normal `pull_request` workflow already supports reviewed fork
code. In that mode, the action checks the commenter's repository permission and
requires `write`, `maintain` or `admin`. The comment is the maintainer's explicit
approval for the resolved head SHA.

Do not dispatch the base branch and then check out the fork SHA. That gives
untrusted code the base branch's cache scope and CodeQL reports it as cache
poisoning. Use the fork handoff instead:

1. Call `start` with `allow-forks: "true"`.
2. If `is-fork` is `true`, call `queue-fork` with the returned filter, focus,
   target, and head SHA. It records the authorized request and toggles the
   internal `e2e-fork-request` label. Pass a GitHub App or PAT token: GitHub
   deliberately prevents events created by `GITHUB_TOKEN` from starting another
   workflow.
3. A small `pull_request: labeled` workflow calls `resolve-fork`. The action
   accepts only an event and request comment from `trusted-bot` for the event's
   exact head SHA.
4. Run the suite from that pull request workflow. It keeps GitHub's native fork
   approval and cache isolation.

Complete the privileged command check as `neutral` once the request is queued.
The pull request workflow's native check reports the suite result.

## Who may run it

From `author_association` in the event payload: `OWNER`, `MEMBER` and
`COLLABORATOR` may, anything else may not, and an empty value is a no rather
than a default yes.

Be precise about what that means, because the output is named `should-run` and
could be read as more than it is. An association is not a permission level.
`MEMBER` means organization membership, not access to this repository, and
`COLLABORATOR` says someone was added without saying at what level, so a
read-only collaborator passes. That coarse check remains sufficient for a
same-repository command. When `allow-forks` is enabled, the action performs the
precise permission lookup and refuses anyone below write access.

## Modes

`start` parses the comment, authorizes the commenter, resolves the pull request,
and opens the check-run. A same-repository request takes two API calls. An
allowed fork takes one additional permission lookup. A comment that is not a
command takes none.

`finish` resolves the terminal outcome and completes it. Give it the check-run
id from `start` and the raw job results; it computes the conclusion so the
matrix lives in a tested script rather than in workflow YAML.

`queue-fork` writes the authorized request to a bot comment and toggles the
internal request label. Its `github-token` must be a GitHub App or PAT token
with pull request write access; the built-in `GITHUB_TOKEN` cannot trigger the
follow-up workflow.

`resolve-fork` reads that request from a `pull_request: labeled` run, verifies
the event actor and request comment match `trusted-bot`, and refuses if the pull
request head no longer matches the approved SHA. It returns the filter, focus,
and target and requires `pull-requests: read`.

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

## Optional focus parsing

Set `parse-focus: "true"` when the command accepts a trailing focus expression:

```text
/test-e2e snapshots --focus "creates a snapshot"
```

The label filter must come first and `--focus` must be the final option; the
whole remaining value becomes the focus. One matching pair of outer quotes is
removed only when it encloses the whole expression. An unescaped inner matching
quote leaves the value as typed. Whitespace inside the expression remains
significant. Spaces or tabs may separate the filter, marker and expression. The
action only parses the two values—the caller decides how to combine them. With
`run-ginkgo`, Ginkgo ANDs the label filter and focus, so the focus can only
narrow the selected suite.

## Optional target parsing

Set `target-name` when one command can route the same filter to independently
dispatched targets. This enables target parsing; the accepted targets default
to `pro oss` and can be overridden with `allowed-targets`:

```text
/test-e2e private-nodes --target pro
/test-e2e coredns --target oss --focus "resolves a service"
```

`--target` follows the label filter and must immediately precede an optional
final `--focus`. The value is one token matched exactly against the
whitespace-separated allowlist. A missing value reports `malformed-target`; a
value outside the allowlist reports `invalid-target`.

A caller that invokes this action once per target sets `target-name` on each
invocation. An explicit different target returns `target-not-selected`
before authorization or API calls, so it opens no check-run. An omitted target
selects every invocation and preserves the existing fan-out behavior.
Every value in `allowed-targets` needs a matching invocation.
`target-not-selected` is silent; do not render it as a refusal.

## Permissions

`start` and `finish` need `checks: write`; `start` also needs
`pull-requests: read`. `queue-fork` needs `pull-requests: write`, while
`resolve-fork` needs `pull-requests: read`. Repository metadata is always
readable by `GITHUB_TOKEN`; fork mode uses it to check the commenter's
permission.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED |           DEFAULT            |                                                                                                           DESCRIPTION                                                                                                            |
|--------------------|--------|----------|------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    allow-forks     | string |  false   |          `"false"`           |   start mode. Allow fork pull requests <br>only when the commenter has write, <br>maintain, or admin repository permission. Disabled <br>by default; use queue-fork and resolve-fork <br>to preserve pull_request isolation.     |
|  allowed-targets   | string |  false   |         `"pro oss"`          |                                             start mode. Whitespace-separated target values accepted <br>when target-name is set. Each value <br>needs a matching action invocation.                                              |
| author-association | string |  false   |                              | start mode. How the commenter relates <br>to the repository. Pass the github.event.comment.author_association <br>context. OWNER, MEMBER and COLLABORATOR may <br>run the command; anything else, including <br>empty, may not.  |
|    build-result    | string |  false   |                              |                                                                            finish mode. Result of the build <br>job. Pass the matching needs result.                                                                             |
| check-name-prefix  | string |  false   |           `"e2e"`            |                                                            start mode. Prefix for the check-run <br>name; the filter and optional target <br>and focus are appended.                                                             |
|    check-run-id    | string |  false   |                              |                                                          finish mode. The id returned by <br>start mode. Empty is not an <br>error; it means no check was <br>opened.                                                            |
|      command       | string |  false   |        `"/test-e2e"`         |                                                                               Command word that must open the <br>comment, on its own first line.                                                                                |
|   comment-author   | string |  false   |                              |                                                                    start mode. Login of the commenter. <br>Pass the github.event.comment.user.login context.                                                                     |
|    comment-body    | string |  false   |                              |                                                                          start mode. The comment text. Pass <br>the github.event.comment.body context.                                                                           |
|    details-url     | string |  false   |                              |                                                                                    finish mode. Link target for the <br>completed check-run.                                                                                     |
|    github-token    | string |  false   |   `"${{ github.token }}"`    |                                             Token for gh. queue-fork requires a <br>GitHub App or PAT token because <br>events created by GITHUB_TOKEN do not <br>start workflows.                                               |
|        mode        | string |   true   |                              |                                                                                 One of "start", "finish", "queue-fork", or <br>"resolve-fork".                                                                                   |
|    parse-focus     | string |  false   |          `"false"`           |                                        start mode. Set to true to <br>split an optional trailing --focus expression <br>from the filter. Disabled by default <br>for existing consumers.                                         |
|    pr-head-sha     | string |  false   |                              |                                                                                  resolve-fork mode. Head SHA from the <br>pull_request event.                                                                                    |
|     pr-number      | string |  false   |                              |                                                                            Pull request number. Required by start, <br>queue-fork, and resolve-fork.                                                                             |
|        repo        | string |  false   | `"${{ github.repository }}"` |                                                                                                  Repository in owner/name form.                                                                                                  |
| report-conclusion  | string |  false   |                              |                                         finish mode. What the test run <br>declared about itself, parsed from its <br>report. The only input that can <br>produce a neutral conclusion.                                          |
|   request-filter   | string |  false   |                              |                                                                                    queue-fork mode. Authorized filter returned by <br>start.                                                                                     |
|   request-focus    | string |  false   |                              |                                                                                    queue-fork mode. Authorized focus returned by <br>start.                                                                                      |
|  request-head-sha  | string |  false   |                              |                                                                                  queue-fork mode. Pull request head SHA <br>returned by start.                                                                                   |
|   request-target   | string |  false   |                              |                                                                                    queue-fork mode. Authorized target returned by <br>start.                                                                                     |
|       run-id       | string |  false   |                              |                                                                  start mode. Used to build the <br>check-run details link. Pass the github.run_id <br>context.                                                                   |
|     server-url     | string |  false   |    `"https://github.com"`    |                                                           start mode. Base URL used to <br>build the check-run details link. Pass <br>the github.server_url context.                                                             |
|    suite-result    | string |  false   |                              |                                                                            finish mode. Result of the suite <br>job. Pass the matching needs result.                                                                             |
|      summary       | string |  false   |                              |                                                                finish mode. Markdown body for the <br>completed check-run. Defaults to the two <br>job results.                                                                  |
|    target-name     | string |  false   |                              |                      start mode. Target represented by this <br>invocation. Setting it enables --target parsing; <br>a different explicit target returns target-not-selected <br>without opening a check.                        |
|    trusted-bot     | string |  false   |         `"loft-bot"`         |                                                                  resolve-fork mode. Login whose App or <br>PAT token queued the label and <br>request comment.                                                                   |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT      |  TYPE  |                                                                                                                                                       DESCRIPTION                                                                                                                                                        |
|-----------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|      args       | string |                                                                                                                                 Raw argument string that followed the <br>command word.                                                                                                                                  |
|    base-ref     | string |                                                                                                                  Resolved base branch of the pull <br>request. The event does not carry <br>it either.                                                                                                                   |
|   check-name    | string |                                                                                                                            Display name of the check-run, sanitized <br>and length-bounded.                                                                                                                              |
|  check-run-id   | string |                                                                                                              Id of the opened check-run. Empty <br>when nothing was opened; gate the <br>finish job on it.                                                                                                               |
|   conclusion    | string |                                                                                                                                   finish mode. The conclusion that was <br>published.                                                                                                                                    |
| concurrency-key | string |                                                Domain-separated request identity reduced to a <br>lowercase slug plus an eight-character digest, <br>safe to interpolate into a concurrency <br>group. Distinct filters, focuses, and targets <br>do not share a group.                                                  |
|  dispatch-ref   | string |                                                                  start mode. Head branch for a <br>same-repository dispatch. Forks return the base <br>branch for identity only; use the <br>fork handoff instead of dispatching fork <br>code there.                                                                    |
|     filter      | string |                                                                                                              Argument string with whitespace normalized. This <br>is what to pass to the <br>test runner.                                                                                                                |
|      focus      | string |                                                                                            Optional focus expression following --focus. One <br>outer quote pair is removed only <br>when it encloses the whole expression.                                                                                              |
|    head-ref     | string |                                                          Resolved head BRANCH of the pull <br>request. Needed by a caller that <br>dispatches the work to a non-privileged <br>run, because `gh workflow run --ref` takes a branch <br>or tag and never a SHA.                                                           |
|    head-sha     | string |                                                                                                                     Resolved head commit of the pull <br>request. The event does not carry <br>it.                                                                                                                       |
|     is-fork     | string |                                                                start mode. "true" when the resolved <br>pull request comes from another repository, <br>"false" for a same-repository pull request, <br>and empty when no pull request <br>was resolved.                                                                 |
|     matched     | string |                                                                                                                                "true" when the comment opened with <br>the command word.                                                                                                                                 |
|     reason      | string | Why the command will not run: <br>fork, insufficient-permission, permission-unreadable, empty-filter, malformed-filter, malformed-focus, <br>malformed-target, invalid-target, target-not-selected, not-a-pull-request, pull-request-closed, pull-request-unreadable, <br>or check-run-not-created. Empty when it will.  |
| reason-guidance | string |                                                                                          start mode. Presentation-ready next step for <br>reason. Empty when the command will <br>run or this invocation was not <br>selected.                                                                                           |
|  reason-title   | string |                                                                                              start mode. Presentation-ready title for reason. <br>Empty when the command will run <br>or this invocation was not selected.                                                                                               |
|   should-run    | string |                                                    The caller's execution gate. "true" only <br>when a check-run was actually opened. <br>Forks are refused unless allow-forks is <br>true and the commenter has write-level <br>permission. Read reason when false.                                                     |
|     target      | string |                                                                                                                  Optional target following --target. Empty means <br>no explicit target was requested.                                                                                                                   |

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
    if: github.event.issue.pull_request && startsWith(github.event.comment.body, '/test-e2e')
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
      # Replace this placeholder with the suite. It must test head-sha and emit
      # one of success, failure, neutral, cancelled, or timed_out.
      - id: run
        run: echo "check-conclusion=success" >> "$GITHUB_OUTPUT"

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

If GitHub accepts the `start` POST but returns an unreadable response or no
check-run id, `start` emits `should-run=false` and the caller does not start the
suite. It cannot close a check-run whose id GitHub did not return. That API
contract failure can therefore leave an `in_progress` check that must be closed
by hand; recovering it automatically would require reintroducing check-run
discovery and reconciliation state.

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

The action deliberately posts no comments. It emits the machine-readable
`reason` plus presentation-ready `reason-title` and `reason-guidance`, which
keeps it usable by repositories that surface results differently. Pair it with
`sticky-pr-comment` when the caller wants a comment.

Render a refusal when `reason` is non-empty and is not
`target-not-selected`. That value is silent routing state for an invocation
that did not own the requested target.

`reason` values: `fork`, `insufficient-permission`, `empty-filter`,
`malformed-filter`, `malformed-focus`, `malformed-target`, `invalid-target`,
`target-not-selected`, `not-a-pull-request`, `pull-request-closed`,
`pull-request-unreadable`, `check-run-not-created`. Empty when the command will
run. For refusals, `reason-title` and `reason-guidance` contain text suitable
for a comment.

`malformed-filter` means the filter's parentheses do not balance. Callers wrap
the filter and append guards, `(<filter>) && !x`; an unmatched `)` ends that
wrapper, and since Ginkgo binds `&&` tighter than `||`, `a) || x` would place
`x` outside the guard.

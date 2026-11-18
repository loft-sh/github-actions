# QA review gate

Turns the review panel's QA verdict into the `qa-review` check-run on the pull
request's head commit, and lets a QA engineer override it or ask for a person
with one comment (ENGQA-1983).

The panel (loft-sh/ai-agents, `pr-review`) posts a COMMENT review as `loft-bot`
whose body ends with one marker line:

```
<!-- qa-review verdict=block classes=a:0,b:1,c:2,d:0 head=<40-char sha> -->
```

| Verdict | Check-run | Meaning |
|---|---|---|
| `block` | failure | a confirmed class a/b/c/d finding: a test is needed, too weak, missing, or the product has a gap |
| `pass` | success | nothing blocks |
| `needs_human` | action_required, QA team requested | the panel could not decide |
| `not_run` | action_required | the QA lanes did not run on this PR; neutral would count as passed once the check is required |

A marker whose `head` is not the PR's current head is ignored, so an old review
never grades a new push.

An automated backport (a PR the panel login opened from a `backport/` branch) was
reviewed on main. On its `opened` event (mode `backport`) both check-runs complete
as success at once on the head the bot opened it with, so the repo's auto-approve
workflow can approve it without waiting on the panel. Any later head, whoever
pushed it, has no check-runs until the panel's verdict and the e2e report grade it
like any other PR. (Commit authorship cannot tell the two apart: a bot backport
keeps the original author.)

Comments on the PR:

- `/qa-review override <reason>` from a login in `qa-logins` completes both
  check-runs (`qa-review` and `qa-review-ci`) as success and records who overrode
  them and why. An override answers a panel verdict, so it lands only when the
  PR's current head carries a panel marker submitted before the comment. A head
  pushed after the comment, or one the panel has not graded yet, gets nothing: the
  job log says so and the QA engineer comments again on what they see. When the
  panel never posted on that head (an outage), `/qa-review override <sha> <reason>`
  names the head instead; it lands only while that sha (7 to 40 hex characters) is
  still the PR head.
- `/qa-review human` from a repository member requests the QA team and leaves
  the check-run as action_required until a person decides.

After the e2e workflow finishes (`workflow_run`, mode `ci`), the action finds the
open PR for the run (from the event, or from the run's head commit when the run was
a `/test-e2e` dispatch). A cancelled run publishes nothing. A run whose head is no
longer the PR head is superseded and ignored. Otherwise it compares the PR base with
the run's own head (the commits the run tested), takes every `It(`, `Specify(` and table
`Entry(` the PR adds under an `e2e` directory with its line in the new file, downloads
the run's `ginkgo-report` artifact, and publishes a second check-run `qa-review-ci`:
failure when a new spec is not in the report or did not pass, success otherwise. A
spec is matched by file and line (the report's `LeafNodeLocation`), never by text, so
an existing spec with the same text cannot stand in for a new one and a skipped
namesake elsewhere cannot fail it. The same location in two reports keeps the worst
state. A PR that adds no spec publishes nothing. A compare the API may have cut (300
files), or a finished run that uploaded no report, gets `action_required`: re-run
`/test-e2e` or a QA engineer overrides.

Requesting the QA team's review (on `needs_human` and `/qa-review human`) is best
effort: when the token cannot name the team, the job logs a warning and stays green.

The action creates check-runs with the job's `GITHUB_TOKEN`; the caller grants
`checks: write` and `pull-requests: write` (`actions: read` too for `ci`). It
never posts review comments.

## Usage

```yaml
permissions:
  checks: write
  pull-requests: write
  contents: read

steps:
  - uses: loft-sh/github-actions/.github/actions/qa-review-gate@qa-review-gate/v1
    with:
      mode: ${{ github.event_name == 'pull_request_review' && 'review' || github.event_name == 'workflow_run' && 'ci' || github.event_name == 'pull_request' && 'backport' || 'comment' }}
      qa-logins: 'adriankabala,sowmyav27,anvesh-loft'
```

The reusable workflow `.github/workflows/qa-review-gate.yaml` wraps this with the
checkout and the event filter.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT     |  TYPE  | REQUIRED |         DEFAULT         |                                                                                      DESCRIPTION                                                                                       |
|--------------|--------|----------|-------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|  check-name  | string |  false   |      `"qa-review"`      |                                                                            Name of the check-run to create.                                                                            |
| github-token | string |  false   | `"${{ github.token }}"` |                            Token for gh. The calling job <br>must grant checks: write and pull-requests: <br>write; ci mode also needs actions: <br>read.                              |
|     mode     | string |   true   |                         | "review" (pull_request_review event), "comment" (issue_comment event), "ci" (workflow_run event of the e2e workflow) <br>or "backport" (pull_request event of an automated backport).  |
| panel-login  | string |  false   |      `"loft-bot"`       |                                     Login that posts the panel review <br>and opens automated backports. Reviews by <br>anyone else are ignored.                                       |
|  qa-logins   | string |  false   |                         |                                                            Comma-separated logins allowed to run /qa-review <br>override.                                                              |
|   qa-team    | string |  false   |   `"loft-sh/eng-qa"`    |                                     org/slug of the team asked for <br>a review on needs_human or /qa-review <br>human. Empty skips the request.                                       |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->
No outputs.
<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-qa-review-gate
```

Runs the pytest suite in `test/` against `src/gate.py`. No network: `apply` and
`collect_ci` are the only functions that call `gh`, and the tests never reach them.

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
| `not_run` | neutral | the QA lanes did not run on this PR |

A marker whose `head` is not the PR's current head is ignored, so an old review
never grades a new push.

Comments on the PR:

- `/qa-review override <reason>` from a login in `qa-logins` completes the
  check-run as success and records who overrode it and why.
- `/qa-review human` from a repository member requests the QA team and leaves
  the check-run as action_required until a person decides.

The action creates check-runs with the job's `GITHUB_TOKEN`; the caller grants
`checks: write` and `pull-requests: write`. It never posts review comments.

## Usage

```yaml
permissions:
  checks: write
  pull-requests: write
  contents: read

steps:
  - uses: loft-sh/github-actions/.github/actions/qa-review-gate@qa-review-gate/v1
    with:
      mode: ${{ github.event_name == 'pull_request_review' && 'review' || 'comment' }}
      qa-logins: 'adriankabala,sowmyav27,anvesh-loft'
```

The reusable workflow `.github/workflows/qa-review-gate.yaml` wraps this with the
checkout and the event filter.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT     |  TYPE  | REQUIRED |         DEFAULT         |                                                  DESCRIPTION                                                  |
|--------------|--------|----------|-------------------------|---------------------------------------------------------------------------------------------------------------|
|  check-name  | string |  false   |      `"qa-review"`      |                                       Name of the check-run to create.                                        |
| github-token | string |  false   | `"${{ github.token }}"` |           Token for gh. The calling job <br>must grant checks: write and pull-requests: <br>write.            |
|     mode     | string |   true   |                         |               Either "review" (pull_request_review event) or "comment" (issue_comment event).                 |
| panel-login  | string |  false   |      `"loft-bot"`       |                  Login that posts the panel review. <br>Reviews by anyone else are ignored.                   |
|  qa-logins   | string |  false   |                         |                        Comma-separated logins allowed to run /qa-review <br>override.                         |
|   qa-team    | string |  false   |   `"loft-sh/eng-qa"`    | org/slug of the team asked for <br>a review on needs_human or /qa-review <br>human. Empty skips the request.  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->
No outputs.
<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-qa-review-gate
```

Runs the pytest suite in `test/` against `src/gate.py`. No network: `apply` is the
only function that calls `gh`, and the tests replace it.

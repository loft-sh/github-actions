# Sticky PR Comment

Upserts a sticky comment on a pull request, identified by a stable HTML
marker. If a comment with the marker already exists it is updated in place,
otherwise a new comment is created. Domain-agnostic — the caller composes
the body. Uses the GitHub CLI (`gh`), pre-installed on hosted runners.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |                   DEFAULT                   |                                                                                                                                                    DESCRIPTION                                                                                                                                                    |
|-----------------|--------|----------|---------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|      body       | string |   true   |                                             |                                                                                                 Markdown body of the comment. The <br>marker is prepended automatically if it <br>is not already the first line.                                                                                                  |
| expected-author | string |  false   |           `"github-actions[bot]"`           | Login of the comment author to <br>match. Comments with the marker but <br>a different author are ignored, so <br>users cannot squat on the sticky <br>slot. Defaults to "github-actions[bot]" which is <br>the author when secrets.GITHUB_TOKEN is used; <br>override when posting via a PAT <br>or GitHub App.  |
|  github-token   | string |   true   |                                             |                                                                                                                  GitHub token. The caller must grant <br>pull-requests: write at the job level.                                                                                                                   |
|     marker      | string |   true   |                                             |                                                                                       HTML comment uniquely identifying this comment <br>stream (e.g. "<!-- e2e-status -->"). Must be of the <br>form "<!-- some-id -->".                                                                                         |
|    pr-number    | string |  false   | `"${{ github.event.pull_request.number }}"` |                                                                                                                       Pull request number. Defaults to the <br>current pull_request event.                                                                                                                        |
|      repo       | string |  false   |        `"${{ github.repository }}"`         |                                                                                                                      Repository in owner/name form. Defaults to <br>the current repository.                                                                                                                       |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT    |  TYPE  |             DESCRIPTION             |
|--------------|--------|-------------------------------------|
| action-taken | string |   Either "created" or "updated".    |
|  comment-id  | string | Numeric ID of the upserted comment. |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Run tests
        id: tests
        run: ./run-tests.sh

      - name: Upsert sticky status comment
        if: always() && github.event_name == 'pull_request'
        uses: loft-sh/github-actions/.github/actions/sticky-pr-comment@sticky-pr-comment/v1
        with:
          marker: '<!-- e2e-status -->'
          body: |
            ### E2E Tests

            | Status | Commit | Run |
            |---|---|---|
            | ${{ steps.tests.outcome == 'success' && '✅ Passed' || '❌ Failed' }} | `${{ github.event.pull_request.head.sha }}` | [#${{ github.run_id }}](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}) |
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

The marker must be a self-contained HTML comment (e.g. `<!-- e2e-status -->`).
It is automatically prepended to `body` when missing, so callers can either
include it explicitly or omit it.

### Sticky semantics

The action is invoked from inside a job. When the caller's job is **skipped**
by an `if:` condition, this action never runs and the previous comment stays
in place — that's exactly the "preserve last real result" behavior most
callers want. Make sure callers do **not** put the upsert step in a separate
job that runs unconditionally; otherwise skipped runs will overwrite the
last real status.

### Permissions

The token passed to `github-token` must have `pull-requests: write`. The
caller is responsible for granting the permission at job level:

```yaml
permissions:
  contents: read
  pull-requests: write
```

## Testing

```bash
make test-sticky-pr-comment
```

Runs the bats suite in `test/` against `src/upsert-comment.sh` with a stubbed
`gh` on `PATH`.

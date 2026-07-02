# Link Backport PRs to Linear

A GitHub Action that links sorenlouv-created backport pull requests to the matching Linear sub-issue, so each backport closes the right per-release-line issue when it merges.

## What it does

When a merged source PR carries `backport-to-<branch>` labels, the [sorenlouv backport action](https://github.com/sorenlouv/backport-github-action) opens one backport PR per label. This action runs right after and, for each backport target:

1. Resolves the source PR's Linear issue (the parent) via Linear's `attachmentsForURL` reverse lookup, falling back to a `TEAM-123` identifier parsed from the branch name or body.
2. Finds the sub-issue whose title carries the release-line prefix for that target, e.g. `[0.34] Copy of ENGCP-906` for a backport to `v0.34` (a leading `v`, as in `[v0.34]`, is also accepted).
3. Appends `Fixes <sub-issue-id>` to that backport PR's body, unless it already references the issue.

The match is by title prefix, not milestone: the `[X.Y] Copy of ...` sub-issues created for a backport family do not reliably carry a patch milestone, so the title is the dependable key.

It is advisory and idempotent: it never fails the backport job (every error is a warning and it exits 0), it skips entirely when no `linear-token` is provided, and re-runs do not add duplicate `Fixes` lines.

## Usage

This action is wired into the shared [`backport.yaml`](../../workflows/backport.yaml) reusable workflow. A caller enables linking by passing a Linear token:

```yaml
jobs:
  backport:
    uses: loft-sh/github-actions/.github/workflows/backport.yaml@backport/v1
    secrets:
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
      linear-token: ${{ secrets.LINEAR_API_TOKEN }}
```

To run it directly:

```yaml
- uses: loft-sh/github-actions/.github/actions/link-backport-prs@link-backport-prs/v1
  with:
    source-pr: ${{ github.event.pull_request.number }}
    repo-owner: ${{ github.repository_owner }}
    repo-name: ${{ github.event.repository.name }}
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
    linear-token: ${{ secrets.LINEAR_API_TOKEN }}
```

The `github-token` must be the same PAT that created the backport PRs (a PAT, not the default `GITHUB_TOKEN`, so the backport PRs exist and are editable).

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT     |  TYPE  | REQUIRED |     DEFAULT      |                                                                                                                                  DESCRIPTION                                                                                                                                  |
|--------------|--------|----------|------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|   dry-run    | string |  false   |    `"false"`     |                                                                                                                   Log intended edits without applying them                                                                                                                    |
| github-token | string |   true   |                  |                                                                             GitHub token with permission to read <br>and edit pull requests (must be the same PAT that created the backport PRs)                                                                              |
| label-prefix | string |  false   | `"backport-to-"` |                                                                                                              Prefix of the backport labels on <br>the source PR                                                                                                               |
| linear-token | string |  false   |                  | Linear API token for resolving the <br>issue family. Optional by design: this <br>is an advisory step, so when <br>empty the action no-ops and exits <br>0 instead of failing, letting callers <br>adopt the shared backport workflow before <br>a Linear token is wired up.  |
|  repo-name   | string |   true   |                  |                                                                                                                          The name of the repository                                                                                                                           |
|  repo-owner  | string |   true   |                  |                                                                                                                          The owner of the repository                                                                                                                          |
|  source-pr   | string |   true   |                  |                                                                                                        The merged source pull request number <br>that was backported                                                                                                          |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->
No outputs.
<!-- AUTO-DOC-OUTPUT:END -->

## Development

### Testing

Run the unit tests:

```bash
./test.sh
# or
make test-link-backport-prs
```

The tests cover the pure matching logic: release-line extraction from a target branch, title-prefix matching (`[0.34]` and `[v0.34]`), sub-issue selection within an issue family, idempotency of the `Fixes` line, and identifier extraction fallback.

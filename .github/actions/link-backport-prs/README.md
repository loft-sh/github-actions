# Link Backport PRs to Linear

A GitHub Action that links modern and legacy backport pull requests to the matching Linear sub-issue, so each backport closes the right per-release-line issue when it merges.

## What it does

When a merged source PR carries `backport-to-<branch>` labels, the shared workflow creates modern backports with [sorenlouv](https://github.com/sorenlouv/backport-github-action) and optional pre-monorepo backports with `backport-legacy-split`. This action runs after both producers settle and, for each backport target:

1. Resolves every Linear issue attached to the source PR via `attachmentsForURL`, then selects the issue family whose children match the requested release lines. A `TEAM-123` identifier parsed from the branch name or body breaks ties and remains the fallback.
2. Finds the sub-issue whose title carries the release-line prefix for that target, e.g. `[0.34] Copy of ENGCP-906` for a backport to `v0.34` (a leading `v`, as in `[v0.34]`, is also accepted).
3. Verifies the release attached to the matched sub-issue agrees with the backport target line, warning on a missing or mismatched release (see below). Linking proceeds either way.
4. Finds the modern `backport/<target>/pr-<source>` PR in the source repo and any legacy `backport/<target>/<short-sha>` PRs in the configured pro and OSS repos. A match must come from the repository being searched, so a fork cannot copy the branch name and body to receive a privileged edit.
5. Appends `Fixes <sub-issue-id>` to every matching PR body, unless it already references the issue.

The match is by title prefix, not milestone: the `[X.Y] Copy of ...` sub-issues created for a backport family do not reliably carry a patch milestone, so the title is the dependable key. A normal issue may itself be nested under a broader issue. In that case, the action searches its own backport children instead of treating it as a backport copy and searching its siblings.

The release check exists because a title match alone cannot catch a sub-issue attached to the wrong release. After a title match, the action reads the Releases attached to the sub-issue via Linear and derives each release's `X.Y` line from its version field, falling back to the leading version in the release name (`0.33.5 - Security Only` parses to `0.33`). No release attached, or no attached release on the target's line, produces a remedy warning. A matching release stays silent. If the releases query itself fails, verification degrades to a single warning and linking continues.

It is advisory and idempotent: it never fails the backport job (every problem is a warning and it exits 0) and re-runs do not add duplicate `Fixes` lines. A lookup failure in one repository is reported without discarding matches found in another repository.

Every skip that a human can fix is loud. When a source PR carries backport labels but linking hits a dead end, the action emits a GitHub `::warning::` annotation and a job-summary line naming the remedy. This covers an empty `linear-token` (fix the repository secret), an unresolved parent Linear issue (attach the PR to its issue), a release line with no matching `[X.Y]` sub-issue (create or rename the sub-issue), a matched sub-issue with no release attached (attach the line's In Progress release), a matched sub-issue whose release is on a different line (fix the release attachment or the sub-issue title), and a target whose producer opened no PR (backport it manually after the conflict). A source PR with no backport labels stays a plain notice, since there is nothing to fix. The step always publishes a `linked-count` output, 0 when it skips.

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
    additional-repos: loft-sh/vcluster,loft-sh/vcluster-pro
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
    linear-token: ${{ secrets.LINEAR_API_TOKEN }}
```

The `github-token` must be the same PAT that created the backport PRs (a PAT, not the default `GITHUB_TOKEN`, so the backport PRs exist and are editable).

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED |     DEFAULT      |                                                                                                                                                                                     DESCRIPTION                                                                                                                                                                                     |
|------------------|--------|----------|------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| additional-repos | string |  false   |                  |                                                                                                       Comma-separated owner/repo list to search for <br>cross-repo legacy backport PRs. The source <br>repository is always searched and duplicate <br>entries are ignored.                                                                                                         |
|     dry-run      | string |  false   |    `"false"`     |                                                                                                                                                                      Log intended edits without applying them                                                                                                                                                                       |
|   github-token   | string |   true   |                  |                                                                                                                                GitHub token with permission to read <br>and edit pull requests (must be the same PAT that created the backport PRs)                                                                                                                                 |
|   label-prefix   | string |  false   | `"backport-to-"` |                                                                                                                                                                 Prefix of the backport labels on <br>the source PR                                                                                                                                                                  |
|   linear-token   | string |  false   |                  | Linear API token for resolving the <br>issue family and verifying release attachments. <br>Optional: the step always exits 0, <br>so callers can adopt the backport <br>workflow before a token is wired <br>up. When it is empty but <br>the source PR carries backport labels, <br>the step emits a warning naming <br>the missing secret instead of silently <br>doing nothing.  |
|    repo-name     | string |   true   |                  |                                                                                                                                                                             The name of the repository                                                                                                                                                                              |
|    repo-owner    | string |   true   |                  |                                                                                                                                                                             The owner of the repository                                                                                                                                                                             |
|    source-pr     | string |   true   |                  |                                                                                                                                                           The merged source pull request number <br>that was backported                                                                                                                                                             |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT    |  TYPE  |                                   DESCRIPTION                                    |
|--------------|--------|----------------------------------------------------------------------------------|
| linked-count | string | Number of backport PRs linked to <br>a Linear sub-issue (0 when the step skips)  |

<!-- AUTO-DOC-OUTPUT:END -->

## Development

### Testing

Run the unit tests:

```bash
./test.sh
# or
make test-link-backport-prs
```

The tests cover modern and legacy PR discovery, trusted head-repository checks, partial repository lookup failures, mixed pro and OSS edits, repository parsing, workflow ordering, release-line extraction, title-prefix matching, sub-issue selection, idempotency of the `Fixes` line, release verification, remedy-warning rendering, and the `linked-count` / job-summary writers.

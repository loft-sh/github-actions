# Select Backport Source PRs

Selects the source pull requests that a backport link sweep should re-check.
Pass `source-pr` to select one family without a search. Leave it empty to find
merged pull requests inside the lookback window that carry a `backport-to-*`
label.

The action is read-only. It emits a JSON array for a workflow matrix and writes
the selected source PRs to the job summary. GitHub search or input failures fail
the step so a missed scheduled sweep cannot look healthy.
The step also fails if the search reaches GitHub's 1,000-result cap, so callers
must reduce the lookback instead of silently missing source PRs.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT     |  TYPE  | REQUIRED |     DEFAULT      |                                           DESCRIPTION                                           |
|---------------|--------|----------|------------------|-------------------------------------------------------------------------------------------------|
| github-token  | string |   true   |                  |           GitHub token with permission to search <br>pull requests in the repository            |
| label-prefix  | string |  false   | `"backport-to-"` |                 Prefix of the labels that mark <br>a source PR for backporting                  |
| lookback-days | string |  false   |      `"30"`      |      Number of days to search back <br>for merged source PRs when source-pr <br>is empty        |
|  repository   | string |   true   |                  |                            Repository to search, in owner/repo form                             |
|   source-pr   | string |  false   |                  | Optional source PR number. When set, <br>return only this PR and skip <br>the lookback search.  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT     |  TYPE  |                  DESCRIPTION                  |
|----------------|--------|-----------------------------------------------|
| selected-count | string |         Number of selected source PRs         |
|   source-prs   | string | JSON array of selected source PR <br>numbers  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
- id: select
  uses: loft-sh/github-actions/.github/actions/select-backport-source-prs@select-backport-source-prs/v1
  with:
    repository: ${{ github.repository }}
    lookback-days: '30'
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

## Tests

```bash
bats .github/actions/select-backport-source-prs/test/*.bats
```

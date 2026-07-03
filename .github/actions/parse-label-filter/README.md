# Parse label filter

Parses the ` ```label-filter``` ` fenced block from a pull request description,
resolves the Ginkgo label filter for an E2E run, and decides whether a
`pull_request` `edited` event can be skipped.

## Why skip-edited exists

E2E workflows commonly trigger on `pull_request: types: [..., edited]` so that
editing the label-filter block re-targets which suites run without pushing a
commit. The side effect is that any bot editing the PR description (for example
`cursor[bot]`) fires `edited` on the same head SHA with no code change, which
re-runs the whole suite.

This action compares the label-filter block before and after the edit. When it
is unchanged there is nothing new to test, so `skip-edited` is `"true"` and the
caller gates its expensive jobs on it. Real triggers (open, reopen, new commits,
and genuine label-filter edits) are never skipped.

Pair this with a concurrency group that separates edited from code events, e.g.
`...-${{ github.event.action == 'edited' && 'edited' || 'code' }}`, so a bot
edit cannot cancel a still-running code run and then skip.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED | DEFAULT |                                                                          DESCRIPTION                                                                          |
|--------------------|--------|----------|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    event-action    | string |  false   |         |                                                 The event action. Pass the github.event.action <br>context.                                                   |
|     event-name     | string |  false   |         |                                                The triggering event. Pass the github.event_name <br>context.                                                  |
| label-filter-input | string |  false   |         | Fallback label filter from a manual <br>dispatch. Pass the ginkgo-label workflow input. <br>Used only when the PR description <br>has no label-filter block.  |
|      pr-body       | string |  false   |         |                                         Current PR description. Pass the github.event.pull_request.body <br>context.                                          |
|  previous-pr-body  | string |  false   |         |                           PR description before an edit. Pass <br>github.event.changes.body.from; only populated on edited events.                            |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT    |  TYPE  |                                                             DESCRIPTION                                                              |
|--------------|--------|--------------------------------------------------------------------------------------------------------------------------------------|
| label-filter | string |             Resolved Ginkgo label filter: the parsed <br>PR-description block, else the dispatch input, <br>else "pr".               |
| skip-edited  | string | Either "true" or "false". "true" only <br>when this is a pull_request edited <br>event whose label-filter block did not <br>change.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
jobs:
  parse-label-filter:
    runs-on: ubuntu-22.04
    outputs:
      label-filter: ${{ steps.parse.outputs.label-filter }}
      skip-edited: ${{ steps.parse.outputs.skip-edited }}
    steps:
      - name: Parse label filter
        id: parse
        uses: loft-sh/github-actions/.github/actions/parse-label-filter@parse-label-filter/v1
        with:
          pr-body: ${{ github.event.pull_request.body }}
          previous-pr-body: ${{ github.event.changes.body.from }}
          event-name: ${{ github.event_name }}
          event-action: ${{ github.event.action }}
          label-filter-input: ${{ inputs.ginkgo-label }}

  e2e-tests:
    needs: [parse-label-filter]
    # Skip a no-op description edit; everything else runs.
    if: needs.parse-label-filter.outputs.skip-edited != 'true'
    runs-on: large-8_32
    steps:
      - run: echo "label filter is ${{ needs.parse-label-filter.outputs.label-filter }}"
```

The label-filter block in a PR description looks like:

````markdown
```label-filter
db-datasource && aws
```
````

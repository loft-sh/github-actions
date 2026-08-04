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

## Tell it which field the edit touched

`edited` fires for the title, the body, the base branch and more, and the payload
carries a `changes` key only for what actually changed. So comparing bodies alone
cannot tell a title edit from a body edit: a non-body edit sends an empty
`previous-pr-body`, which reads as *"the label-filter block was removed"*.

Pass both booleans so the three cases separate — they have different answers, and
one flag cannot express them:

```yaml
  body-changed: ${{ github.event.changes.body != null }}
  base-changed: ${{ github.event.changes.base != null }}
```

| `edited` carrying | verdict | why |
|---|---|---|
| `changes.title` only | **skip** | title, labels, assignees cannot change a filter that lives in the body |
| `changes.body` | compare the blocks | the filter may have moved |
| `changes.base` | **never skip** | a different base can mean a different thing under test |

The base case is why `body-changed` alone is not enough: a retarget carries no
body change, so it would report as skippable — but a caller that resolves
anything from `base_ref` (an OSS branch, a chart line) is now testing a different
pairing and the previous result does not carry over.

### Both lines or neither

The two are **one wiring**, and the action only acts on the pair. Copy just
`body-changed` and nothing is skipped that would not be skipped today: the action
cannot tell your omitted `base-changed` from a `base-changed: false`, so honouring
`body-changed` alone would suppress the suite on exactly the base retarget the
table says must always run. Half-wired therefore falls back to comparing the
blocks — a redundant run — and warns, rather than skipping.

Both inputs are optional and omitting both keeps the legacy body comparison, so
adopting this needs no coordinated rollout. That legacy path still misreads a
title-only edit as a filter change, which costs a redundant suite — worse when
the concurrency guard above means it queues rather than replacing. A test pins
that behaviour, so the cost of omitting them is explicit rather than folklore.

Only the exact strings `"false"` and `"true"` are acted on; anything else falls
back to comparing, so a caller expression that renders oddly cannot produce a
silent skip. It does warn, because otherwise a broken expression and a caller
that never wired the inputs read identically in the log.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED | DEFAULT |                                                                          DESCRIPTION                                                                          |
|--------------------|--------|----------|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    base-changed    | string |  false   |         |   Whether this edit retargeted the base <br>branch. Pass a null test on <br>the changes.base payload key, together with <br>body-changed; see the README.     |
|    body-changed    | string |  false   |         |       Whether this edit touched the PR <br>body. Pass a null test on <br>the changes.body payload key, together with <br>base-changed; see the README.        |
|    event-action    | string |  false   |         |                                                 The event action. Pass the github.event.action <br>context.                                                   |
|     event-name     | string |  false   |         |                                                The triggering event. Pass the github.event_name <br>context.                                                  |
| label-filter-input | string |  false   |         | Fallback label filter from a manual <br>dispatch. Pass the ginkgo-label workflow input. <br>Used only when the PR description <br>has no label-filter block.  |
|      pr-body       | string |  false   |         |                                         Current PR description. Pass the github.event.pull_request.body <br>context.                                          |
|  previous-pr-body  | string |  false   |         |                           PR description before an edit. Pass <br>github.event.changes.body.from; only populated on edited events.                            |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT    |  TYPE  |                                                                                        DESCRIPTION                                                                                         |
|--------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| label-filter | string |                                        Resolved Ginkgo label filter: the parsed <br>PR-description block, else the dispatch input, <br>else "pr".                                          |
| skip-edited  | string | Either "true" or "false". "true" only <br>when this is a pull_request edited <br>event that cannot have changed what <br>the suite would test; see the <br>README for the per-field rule.  |

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
          # Part of the usage, not an optional extra: without these, a
          # title-only edit is misread. Wire both lines or neither — one
          # alone is ignored, and warns. See above.
          body-changed: ${{ github.event.changes.body != null }}
          base-changed: ${{ github.event.changes.base != null }}
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

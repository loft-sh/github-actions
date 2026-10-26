# Conflict Check

Scans every tracked text file in the checked-out repository for git conflict
markers (`<<<<<<< ` and `>>>>>>> ` at the start of a line), whatever the file
extension. `vendor` and `node_modules` are skipped, and so are binary files.
`=======` is not matched, because Markdown uses it as a heading underline.

The action only reports. It never fails on markers, so the caller decides what
to do with them. A scan that cannot run (for example, no git checkout) fails the
step instead of reporting a clean result.

Released under the `conflict-check/v1` tag, the same tag as the
`conflict-check.yaml` reusable workflow.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->
No inputs.
<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT    |  TYPE  |                                        DESCRIPTION                                         |
|-------------|--------|--------------------------------------------------------------------------------------------|
|    found    | string |              "true" when conflict markers were found, <br>"false" otherwise.               |
| report-file | string | Path to a Markdown report listing <br>the markers. Written only when found <br>is "true".  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
steps:
  - uses: actions/checkout@<sha> # vX
    with:
      persist-credentials: false
  - id: conflicts
    uses: loft-sh/github-actions/.github/actions/conflict-check@conflict-check/v1
  - if: steps.conflicts.outputs.found == 'true'
    run: exit 1
```

## Testing

```bash
make test-conflict-check
```

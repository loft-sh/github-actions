# Derive Ginkgo check conclusion

Turn a Ginkgo JSON report into a GitHub check-run conclusion. The action distinguishes successful, failed, timed-out, and empty selections so callers do not accidentally publish a passing check when Ginkgo selected no specs.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|           INPUT            |  TYPE  | REQUIRED |           DEFAULT            |                                                                                                                                                                                                                                DESCRIPTION                                                                                                                                                                                                                                 |
|----------------------------|--------|----------|------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| empty-selection-conclusion | string |  false   |         `"neutral"`          | What to report when the filter <br>matched no specs. Defaults to neutral, <br>which is what the gate wants: <br>its filter always ORs in the <br>mandatory suite, so an empty selection <br>there means something odd rather than <br>a mistake. A caller whose filter <br>is typed by hand should pass <br>failure, because GitHub renders neutral as <br>a grey non-blocking check and "nothing <br>ran" then reads as fine. Only <br>neutral and failure are accepted.  |
|           focus            | string |  false   |                              |                                                                                                                                                       Optional focus expression used for the <br>run. When set, an empty-selection summary <br>explains that the combined label and <br>focus selection was empty.                                                                                                                                                         |
|           report           | string |  false   | `"test-reports/report.json"` |                                                                                                                                                                                                                      Path to the Ginkgo JSON report.                                                                                                                                                                                                                       |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|      OUTPUT      |  TYPE  |                                                                          DESCRIPTION                                                                          |
|------------------|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| check-conclusion | string |                               One of success, failure, neutral or <br>timed_out. Empty when no readable report <br>was found.                                 |
|  check-summary   | string | Why the check failed, for a <br>caller publishing a check-run. Set only <br>for an empty selection; empty otherwise, <br>so the caller's own default stands.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
- name: Derive check conclusion
  id: conclusion
  if: always()
  uses: loft-sh/github-actions/.github/actions/ginkgo-conclusion@ginkgo-conclusion/v1
  with:
    report: test-reports/report.json
    empty-selection-conclusion: failure
    focus: ${{ inputs.ginkgo-focus }}
```

When the report is missing or unreadable, the action emits no conclusion so the caller can fail closed using the job result. `empty-selection-conclusion` accepts only `neutral` or `failure`; invalid values resolve to `failure`.

## Testing

```bash
make test-ginkgo-conclusion
```

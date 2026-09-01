# Run Ginkgo Tests

Execute Ginkgo tests with directory or label-based filtering and JSON failure
reporting. Handles Ginkgo CLI installation, argument construction, and
markdown summary generation.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|          INPUT          |  TYPE  | REQUIRED |         DEFAULT         |                                                                                                                         DESCRIPTION                                                                                                                         |
|-------------------------|--------|----------|-------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     additional-args     | string |  false   |                         |                                                                                                  Extra arguments passed to the test <br>binary (after --)                                                                                                   |
| additional-ginkgo-flags | string |  false   |                         |                                                                                        Extra ginkgo CLI flags (e.g. -v, --skip-package=linters, --show-node-events)                                                                                         |
|     flake-attempts      | string |  false   |          `"1"`          | Attempts a failing spec gets before <br>the suite reports it failed. Ginkgo <br>retries only that spec. Use 2 <br>on runs where an infra flake <br>must not redden the job (a release bump PR); <br>leave at 1 wherever the signal <br>has to stay honest.  |
|      ginkgo-label       | string |  false   |                         |                                                                                   Ginkgo label filter expression. When set, <br>adds --label-filter and -r (recursive).                                                                                     |
|      github-token       | string |  false   | `"${{ github.token }}"` |                                                                                       GitHub token for the gh CLI <br>to fetch job details during report <br>upload.                                                                                        |
|          procs          | string |  false   |          `"8"`          |                                                                                                             Number of parallel Ginkgo processes                                                                                                             |
|     reports-bucket      | string |  false   |                         |                                                                                                 GCS bucket name for uploading the <br>Ginkgo JSON report.                                                                                                   |
|    rerun-failed-only    | string |  false   |        `"false"`        |                                                                            Set to 'true' to narrow a <br>re-run to the previous attempt's failures. <br>Requires upload-report.                                                                             |
|        test-dir         | string |  false   |      `"e2e-next"`       |                                                                                                              Directory containing test suites                                                                                                               |
|         timeout         | string |  false   |         `"60m"`         |                                                                                                                     Ginkgo test timeout                                                                                                                     |
|      upload-report      | string |  false   |        `"false"`        |                                                         Set to 'true' to upload the <br>Ginkgo JSON report to GCS after <br>the test run. Requires reports-bucket and <br>workflow-file to be set.                                                          |
|      workflow-file      | string |  false   |                         |                                                                         Workflow file name (e.g. e2e-ginkgo.yaml) used as <br>the GCS path segment and report <br>metadata field.                                                                           |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT      |  TYPE  |                                  DESCRIPTION                                  |
|-----------------|--------|-------------------------------------------------------------------------------|
| failure-summary | string |                    Markdown-formatted test results summary                    |
|  focused-rerun  | string | 'true' when this run was narrowed <br>to the previous attempt's failed specs  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
- uses: loft-sh/github-actions/.github/actions/run-ginkgo@run-ginkgo/v1
  with:
    test-dir: e2e-next
    ginkgo-label: "networking"
    additional-args: "--vcluster-image=ghcr.io/loft-sh/vcluster:latest --teardown=false"
```

## Re-running only the failed specs

With `rerun-failed-only: "true"`, hitting **Re-run failed jobs** in the GitHub UI
runs only the specs that did not pass in the previous attempt, instead of the
whole suite. The head SHA is unchanged across attempts, so the specs that passed
in attempt 1 already passed on the exact commit under test.

```yaml
- uses: loft-sh/github-actions/.github/actions/run-ginkgo@run-ginkgo/v1
  with:
    test-dir: e2e
    upload-report: "true"
    rerun-failed-only: "true"
    reports-bucket: ${{ vars.E2E_INSIGHTS_BUCKET }}
    workflow-file: e2e-ginkgo.yaml
```

It reads the previous attempt's report from
`gs://<reports-bucket>/<repo>/<workflow-file>/<run_id>/<attempt-1>/*.json`, so
**`upload-report: "true"` is a prerequisite** — without it nothing ever publishes the
report this reads and the re-run is never narrowed (the action emits a `::warning::`
for that combination). It also needs an authenticated `gcloud` earlier in the job.
Every attempt uploads its own report, so attempt 3 narrows down to what attempt 2
left failing.

The unit of the re-run is the **top-level container** of each failed spec, not the
spec itself. `SpecReport.MarshalJSON` drops `IsInOrderedContainer`, so the report
cannot tell whether a spec sits in an `Ordered` container, and re-running an ordered
spec on its own would skip the siblings it depends on.

Ginkgo matches `--focus` against `<SuiteDescription> <container texts> <It text>`,
compiled with Go's `regexp`. The expression is one anchored `^…$` alternative per
spec sharing a failed container — every spec's exact full text, escaped for RE2 and
joined with `|`. Anchoring each spec rather than prefix-matching the container is
what keeps `Node Profiles` from also pulling in `Node Profiles - selection precedence`.
The `focused-rerun` output is `true` when the narrowing was applied.

It falls back to a full run, with a `::notice::` explaining why, when:

- this is the first attempt of the run;
- no report from the previous attempt is in the bucket, or it cannot be parsed —
  `upload-report.sh` is `continue-on-error`, so a half-written report is normal;
- the previous attempt failed without any failed spec (build or infra failure);
- a suite setup/teardown node (`BeforeSuite`, `AfterSuite`, …) failed, which
  makes a spec-level focus meaningless;
- the previous attempt did not complete — it carries `SpecialSuiteFailureReasons`
  (interrupt, suite timeout) or ran with `--fail-fast`. Ginkgo marks never-executed
  specs `skipped`, indistinguishable in the report from a deliberate skip, so
  narrowing would permanently drop specs that ran in neither attempt.

Note that the report and the summary of a focused re-run only cover the specs that
were re-run; the uploaded report carries `focused_rerun=true` in its GCS metadata so
downstream flakiness stats can exclude it.

**Matrix jobs:** every `*.json` under the previous attempt's prefix is merged, one per
matrix leg, so a leg receives the union of all legs' failures and re-runs the part of
it that exists in its own spec tree. If that intersection is empty — an unrelated
suite, or a leg whose own attempt-1 report never uploaded — Ginkgo would exit 0 having
run nothing, so `generate-summary.sh` fails the job when a focused re-run matches zero
specs. (`--fail-on-empty` is not used for this: Ginkgo applies it per suite, so it
would fail every suite in a `-r` run that the focus legitimately does not target.)

## Testing

```bash
make test-run-ginkgo
```

Runs the bats suites in `test/` against the shell scripts in `src/`, plus the Go
suite in `test/focus/`.

The Go suite exists because asserting on the focus regex as a string cannot catch an
escaping or anchoring mistake. It runs `resolve-rerun-focus.sh` against a fixture,
compiles the resulting expression with `regexp` (what Ginkgo does in
`internal/focus.go`), and replays every spec through it to assert that the selected
set is exactly the failed containers — no failure dropped, no neighbouring container
pulled in.

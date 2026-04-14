# Run Ginkgo Tests

Execute Ginkgo tests with directory or label-based filtering and JSON failure
reporting. Handles Ginkgo CLI installation, argument construction, and
markdown summary generation.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|          INPUT          |  TYPE  | REQUIRED |   DEFAULT    |                                      DESCRIPTION                                       |
|-------------------------|--------|----------|--------------|----------------------------------------------------------------------------------------|
|     additional-args     | string |  false   |              |               Extra arguments passed to the test <br>binary (after --)                 |
| additional-ginkgo-flags | string |  false   |              |     Extra ginkgo CLI flags (e.g. -v, --skip-package=linters, --show-node-events)       |
|      ginkgo-label       | string |  false   |              | Ginkgo label filter expression. When set, <br>adds --label-filter and -r (recursive).  |
|          procs          | string |  false   |    `"8"`     |                          Number of parallel Ginkgo processes                           |
|        test-dir         | string |  false   | `"e2e-next"` |                            Directory containing test suites                            |
|         timeout         | string |  false   |   `"60m"`    |                                  Ginkgo test timeout                                   |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT      |  TYPE  |               DESCRIPTION               |
|-----------------|--------|-----------------------------------------|
| failure-summary | string | Markdown-formatted test results summary |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
- uses: loft-sh/github-actions/.github/actions/run-ginkgo@run-ginkgo/v1
  with:
    test-dir: e2e-next
    ginkgo-label: "networking"
    additional-args: "--vcluster-image=ghcr.io/loft-sh/vcluster:latest --teardown=false"
```

## Testing

```bash
make test-run-ginkgo
```

Runs the bats suites in `test/` against the shell scripts in `src/`.

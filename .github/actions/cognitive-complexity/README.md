# cognitive-complexity

Reports Go functions whose [cognitive complexity](https://github.com/uudashr/gocognit) is above a threshold. The list, highest score first, goes to the job log and the job summary.

The action is report only. It does not fail the job on findings, so a repo can see its backlog before it gates on it. It fails only when `gocognit` itself fails, for example on a parse error.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED |                               DEFAULT                               |                                                                                                DESCRIPTION                                                                                                |
|------------------|--------|----------|---------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| go-version-file  | string |  false   |                             `"go.mod"`                              |                                                                       Path to go.mod (or go.work) passed to <br>actions/setup-go.                                                                         |
| gocognit-version | string |  false   |                             `"v1.3.0"`                              |                                                                      Version of github.com/uudashr/gocognit/cmd/gocognit to install.                                                                      |
|      ignore      | string |  false   | `(^"\|"/)(vendor"\|"third_party"\|"e2e"\|"e2e-next)/"\|"_test\.go$` | Regexp of file paths to skip <br>before parsing. The default skips tests, <br>e2e suites and vendored code. Files <br>with the standard `Code generated ... DO NOT EDIT.` marker are <br>always skipped.  |
|    scan-paths    | string |  false   |                                `"."`                                |                                                                               Space-separated files or directories to scan.                                                                               |
|    threshold     | string |   true   |                                                                     |                                                                     List functions with a cognitive complexity <br>above this value.                                                                      |

<!-- AUTO-DOC-INPUT:END -->

## Usage

```yaml
jobs:
  cognitive-complexity:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/cognitive-complexity@cognitive-complexity/v1
        with:
          threshold: "22"
```

Pick the threshold from the repo's current distribution, for example its p95 score, and lower it as the backlog shrinks.

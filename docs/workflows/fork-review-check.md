# Fork review check

Runs the [fork-review-check](../../.github/actions/fork-review-check/README.md) composite action on the caller's ref, then uploads its JSON evidence receipt as an Actions artifact.

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|    SECRET    | REQUIRED |                           DESCRIPTION                            |
|--------------|----------|------------------------------------------------------------------|
| github-token |  false   | Token for GitHub read APIs. Defaults <br>to the workflow token.  |

<!-- AUTO-DOC-SECRETS:END -->

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE   | REQUIRED |           DEFAULT            |                       DESCRIPTION                       |
|------------------|---------|----------|------------------------------|---------------------------------------------------------|
|     advisory     | boolean |  false   |            `true`            |  Report rule failures without failing the <br>caller.   |
|  artifact-name   | string  |  false   |   `"fork-review-receipt"`    |         Name for the uploaded receipt artifact.         |
|      as-of       | string  |  false   |                              | RFC 3339 release time that approvals <br>must predate.  |
|     binaries     | string  |  false   |                              |    Newline-separated release URL and SHA-256 pairs.     |
|       dirs       | string  |  false   |                              |        Newline-separated Go module directories.         |
|      images      | string  |  false   |                              |      Newline-separated digest-pinned fork images.       |
|       mode       | string  |  false   |           `"scan"`           |                        CLI mode.                        |
|     receipt      | string  |  false   | `"fork-review-receipt.json"` |           Path for the JSON evidence receipt.           |
|       ref        | string  |  false   |                              | Caller ref to check out. Empty <br>uses the event ref.  |
|       root       | string  |  false   |            `"."`             |              Root directory for scan mode.              |
| signer-workflows | string  |  false   |                              |    Newline-separated attestation workflow mappings.     |
|     sources      | string  |  false   |                              |   Newline-separated fork=tag-or-full-SHA source pins.   |
|    upstreams     | string  |  false   |                              |     Newline-separated temporary upstream mappings.      |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT     |                    VALUE                    |              DESCRIPTION               |
|---------------|---------------------------------------------|----------------------------------------|
| artifact-name | `"${{ jobs.check.outputs.artifact-name }}"` | Name of the uploaded receipt artifact. |
|     pass      |     `"${{ jobs.check.outputs.pass }}"`      | Whether every fork review rule passed. |

<!-- AUTO-DOC-OUTPUT:END -->

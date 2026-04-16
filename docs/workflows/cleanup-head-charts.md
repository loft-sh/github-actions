# Cleanup Head Charts

Removes old head chart versions from ChartMuseum, keeping the N most recent.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE   | REQUIRED | DEFAULT |                               DESCRIPTION                               |
|------------------|---------|----------|---------|-------------------------------------------------------------------------|
| chart-museum-url | string  |   true   |         |           ChartMuseum base URL (e.g. https://charts.loft.sh)            |
|    chart-name    | string  |   true   |         |  Chart name to clean up (e.g. vcluster-head, vcluster-platform-head)    |
|     dry-run      | boolean |  false   | `false` | List versions that would be deleted <br>without actually deleting them  |
|   max-versions   | number  |  false   |  `50`   |                   Maximum number of versions to keep                    |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|        SECRET         | REQUIRED |     DESCRIPTION      |
|-----------------------|----------|----------------------|
| chart-museum-password |   true   | ChartMuseum password |
|   chart-museum-user   |   true   | ChartMuseum username |

<!-- AUTO-DOC-SECRETS:END -->

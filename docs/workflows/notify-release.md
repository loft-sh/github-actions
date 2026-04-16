# Notify Release

Sends a Slack notification to #product-releases when a new version is published.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE   | REQUIRED |   DEFAULT   |                                   DESCRIPTION                                   |
|-----------------|---------|----------|-------------|---------------------------------------------------------------------------------|
|     dry-run     | boolean |  false   |   `false`   |    Validate inputs and workflow structure without <br>sending notifications     |
|  previous_tag   | string  |  false   |             |  The previous tag for changelog comparison <br>(required when status=success)   |
|     product     | string  |   true   |             |                 Product name (e.g. vCluster, vCluster Platform)                 |
|       ref       | string  |  false   |             |                The git ref to checkout (defaults to github.ref)                 |
| release_version | string  |   true   |             |                      The release version tag (e.g. v1.2.3)                      |
|     status      | string  |  false   | `"success"` | Release status: success, failure, cancelled, or <br>skipped (default: success)  |
|   target_repo   | string  |   true   |             |                    Target repository (e.g. loft-sh/vcluster)                    |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|               SECRET               | REQUIRED |                   DESCRIPTION                    |
|------------------------------------|----------|--------------------------------------------------|
| SLACK_WEBHOOK_URL_PRODUCT_RELEASES |   true   | Slack incoming webhook URL for #product-releases |

<!-- AUTO-DOC-SECRETS:END -->

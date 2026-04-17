# Auto-approve bot PRs

Reusable workflow that approves PRs from trusted bot accounts whose
title or branch matches a known safe pattern. Wraps the composite action
of the same name with GitHub App token minting and sparse checkout.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE   | REQUIRED |                    DEFAULT                     |                     DESCRIPTION                      |
|-----------------|---------|----------|------------------------------------------------|------------------------------------------------------|
|   auto-merge    | boolean |  false   |                     `true`                     |           Enable auto-merge after approval           |
|  merge-method   | string  |  false   |                   `"squash"`                   | Merge method for auto-merge (squash, merge, rebase)  |
| trusted-authors | string  |  false   | `"renovate[bot],loft-bot,github-actions[bot]"` |      Comma-separated list of trusted bot logins      |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                DESCRIPTION                                |
|-----------------|----------|---------------------------------------------------------------------------|
| gh-access-token |   true   | GitHub PAT for approving PRs (must be different identity from PR author)  |

<!-- AUTO-DOC-SECRETS:END -->

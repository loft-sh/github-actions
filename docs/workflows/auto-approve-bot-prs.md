# Auto-approve bot PRs

Reusable workflow that approves PRs from trusted bot accounts whose
title or branch matches a known safe pattern. Wraps the composite action
of the same name with GitHub App token minting and sparse checkout.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE   | REQUIRED |                    DEFAULT                     |                               DESCRIPTION                               |
|-----------------|---------|----------|------------------------------------------------|-------------------------------------------------------------------------|
|     app-id      | string  |  false   |                                                | GitHub App ID for minting installation <br>tokens (preferred over PAT)  |
|   auto-merge    | boolean |  false   |                     `true`                     |                    Enable auto-merge after approval                     |
|  merge-method   | string  |  false   |                   `"squash"`                   |          Merge method for auto-merge (squash, merge, rebase)            |
| trusted-authors | string  |  false   | `"renovate[bot],loft-bot,github-actions[bot]"` |               Comma-separated list of trusted bot logins                |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                  DESCRIPTION                                  |
|-----------------|----------|-------------------------------------------------------------------------------|
| app-private-key |  false   |       GitHub App private key (PEM) for <br>minting installation tokens        |
| gh-access-token |  false   | GitHub PAT for approving PRs (legacy — use app-id + app-private-key instead)  |

<!-- AUTO-DOC-SECRETS:END -->

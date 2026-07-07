# Backport

Creates backport PRs when a merged PR is labeled with `backport/<branch>`.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->
No inputs.
<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                                                DESCRIPTION                                                                 |
|-----------------|----------|--------------------------------------------------------------------------------------------------------------------------------------------|
| gh-access-token |   true   |                                                    GitHub PAT for creating backport PRs                                                    |
|  linear-token   |  false   | Linear API token for linking backport <br>PRs to their matching Linear sub-issue. <br>Optional; linking is skipped when not <br>provided.  |

<!-- AUTO-DOC-SECRETS:END -->

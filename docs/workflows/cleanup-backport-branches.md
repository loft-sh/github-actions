# Cleanup Backport Branches

Deletes stale backport branches whose parent PR has been merged or closed.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|  INPUT  |  TYPE   | REQUIRED | DEFAULT | DESCRIPTION  |
|---------|---------|----------|---------|--------------|
| dry-run | boolean |  false   | `false` | Dry run mode |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                     DESCRIPTION                     |
|-----------------|----------|-----------------------------------------------------|
| gh-access-token |   true   | GitHub PAT with repo scope for <br>branch deletion  |

<!-- AUTO-DOC-SECRETS:END -->

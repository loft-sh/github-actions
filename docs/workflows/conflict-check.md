# Conflict Check

Labels PRs that have merge conflicts and posts a comment asking the author to rebase.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->
No inputs.
<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                                                                 DESCRIPTION                                                                                  |
|-----------------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| gh-access-token |   true   | GitHub PAT for commenting on PRs. <br>Must be a user token: the <br>comment author is read from /user, <br>which an App installation token or <br>GITHUB_TOKEN cannot call.  |

<!-- AUTO-DOC-SECRETS:END -->

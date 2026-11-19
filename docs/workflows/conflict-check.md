# Conflict Check

Scans a PR for conflict markers. When it finds some, it posts a comment listing them and fails the check. When a later push removes them, it edits that comment to say the conflicts were resolved. PRs that never had conflicts get no comment.

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

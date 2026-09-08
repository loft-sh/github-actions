# Backport Link Sweep

Selects recently merged source PRs with `backport-to-*` labels, or one explicit
source PR, and re-runs the existing backport PR linker for each family. The
selector is read-only. The linker remains advisory and idempotent.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT     |  TYPE   | REQUIRED | DEFAULT |                                                   DESCRIPTION                                                   |
|---------------|---------|----------|---------|-----------------------------------------------------------------------------------------------------------------|
|    dry-run    | boolean |  false   | `false` |                       Report intended Fixes lines without editing <br>backport PR bodies                        |
|    enabled    | boolean |  false   | `true`  |    Run the sweep. Set false through <br>a caller repository variable to disable <br>it without a rollback.      |
| legacy-split  | boolean |  false   | `false` |                Search the configured OSS and pro <br>repositories for legacy split backport PRs                 |
| lookback-days | number  |  false   |  `30`   |              Number of days to search back <br>for merged source PRs when source-pr <br>is empty                |
|   oss-repo    | string  |  false   |         |      OSS repo as owner/repo for legacy <br>OSS-side backport PRs. Required when legacy-split <br>is true.       |
|   pro-repo    | string  |  false   |         | Pro repo as owner/repo for the <br>pro half of mixed legacy backports. <br>Required when legacy-split is true.  |
|   source-pr   | string  |  false   |         |      Optional source PR number. When set, <br>check only this family and bypass <br>the lookback search.        |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                             DESCRIPTION                                             |
|-----------------|----------|-----------------------------------------------------------------------------------------------------|
| gh-access-token |   true   | GitHub PAT used by the backport <br>pipeline, with permission to search and <br>edit pull requests  |
|  linear-token   |  false   |       Linear API token for resolving the <br>issue family and verifying release attachments         |

<!-- AUTO-DOC-SECRETS:END -->

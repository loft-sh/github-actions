# Backport

Creates backport PRs when a merged PR is labeled with `backport/<branch>`.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT      |  TYPE   | REQUIRED | DEFAULT |                                                                                                                                                                                                   DESCRIPTION                                                                                                                                                                                                   |
|----------------|---------|----------|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|  legacy-split  | boolean |  false   | `false` | Enable the pre-monorepo (<= v0.36) split/re-root backport <br>flow. When true this workflow empties <br>auto_backport_label_prefix so sorenlouv honors the caller's <br>.backportrc.json branchLabelMapping regex (which MUST be scoped to the monorepo era, >= v0.37), and a <br>companion job routes <= v0.36 targets <br>through backport-legacy-split. Requires subtree-prefix, oss-repo and <br>pro-repo.  |
|    oss-repo    | string  |  false   |         |                                                                                                                                                      OSS repo as owner/repo for legacy <br>OSS-side backport PRs. Required when legacy-split <br>is true.                                                                                                                                                       |
|    pro-repo    | string  |  false   |         |                                                                                                                                                 Pro repo as owner/repo for the <br>pro half of mixed legacy backports. <br>Required when legacy-split is true.                                                                                                                                                  |
| subtree-prefix | string  |  false   |         |                                                                                                                                            OSS subtree path in the monorepo, <br>e.g. staging/github.com/loft-sh/vcluster. Required when legacy-split is <br>true.                                                                                                                                              |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                                                DESCRIPTION                                                                 |
|-----------------|----------|--------------------------------------------------------------------------------------------------------------------------------------------|
| gh-access-token |   true   |                                                    GitHub PAT for creating backport PRs                                                    |
|  linear-token   |  false   | Linear API token for linking backport <br>PRs to their matching Linear sub-issue. <br>Optional; linking is skipped when not <br>provided.  |

<!-- AUTO-DOC-SECRETS:END -->

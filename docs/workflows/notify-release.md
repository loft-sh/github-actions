# Notify Release

Sends a Slack notification to #product-releases when a new version is published.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE   | REQUIRED |         DEFAULT          |                                                                                                                              DESCRIPTION                                                                                                                              |
|------------------|---------|----------|--------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     dry-run      | boolean |  false   |         `false`          |                                                                                               Validate inputs and workflow structure without <br>sending notifications                                                                                                |
|  is_prerelease   | boolean |  false   |         `false`          |                                                                                 Whether the release was published as <br>a pre-release. Shown as the GitHub <br>label in the banner.                                                                                  |
| needs_promotion  | boolean |  false   |         `false`          |     Set true when the release is <br>published un-promoted (GitHub "None" label) and a human <br>still has to promote it. Adds <br>a promote reminder with a link <br>to promote_workflow. Opt-in, so products that <br>ship straight to Latest are unaffected.       |
|   paired_repo    | string  |  false   |                          | Second repository publishing the same version <br>(e.g. the public OSS repo alongside a private product repo). When set, the banner links <br>the release and changelog for both <br>repos instead of target_repo only. Leave <br>empty for single-release products.  |
|   previous_tag   | string  |  false   |                          |                                                                     The previous tag for changelog comparison. <br>Leave empty for a first release; <br>the banner links release notes instead.                                                                       |
|     product      | string  |   true   |                          |                                                                                                            Product name (e.g. vCluster, vCluster Platform)                                                                                                            |
| promote_workflow | string  |  false   | `"promote-release.yaml"` |                                                                        Workflow file in target_repo that performs <br>the promotion, linked from the banner <br>when needs_promotion is true.                                                                         |
|       ref        | string  |  false   |                          |                                                                                                           The git ref to checkout (defaults to github.ref)                                                                                                            |
| release_version  | string  |   true   |                          |                                                                                                                 The release version tag (e.g. v1.2.3)                                                                                                                 |
|      status      | string  |  false   |       `"success"`        |                                                                                            Release status: success, failure, cancelled, or <br>skipped (default: success)                                                                                             |
|   target_repo    | string  |   true   |                          |                                                                                                               Target repository (e.g. loft-sh/vcluster)                                                                                                               |
|   triggered_by   | string  |  false   |                          |                                Human who triggered the release; forwarded <br>to the Slack banner. Leave empty <br>to fall back to github.actor (the run actor, which is the bot PAT when the release was dispatched cross-workflow).                                 |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|               SECRET               | REQUIRED |                   DESCRIPTION                    |
|------------------------------------|----------|--------------------------------------------------|
| SLACK_WEBHOOK_URL_PRODUCT_RELEASES |   true   | Slack incoming webhook URL for #product-releases |

<!-- AUTO-DOC-SECRETS:END -->

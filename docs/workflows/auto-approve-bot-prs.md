# Auto-approve bot PRs

Reusable workflow that approves PRs from trusted bot accounts whose
title or branch matches a known safe pattern. Wraps the composite action
of the same name, adding a sparse checkout of this repo. It does not mint any
token: the approving PAT is supplied by the caller as the `gh-access-token`
secret.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE   | REQUIRED |                    DEFAULT                     |                                                      DESCRIPTION                                                       |
|--------------------|---------|----------|------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
|     auto-merge     | boolean |  false   |                    `false`                     |                                            Enable auto-merge after approval                                            |
|    merge-method    | string  |  false   |                   `"squash"`                   |                                  Merge method for auto-merge (squash, merge, rebase)                                   |
|  trusted-authors   | string  |  false   | `"renovate[bot],loft-bot,github-actions[bot]"` |                                       Comma-separated list of trusted bot logins                                       |
| wait-max-attempts  | string  |  false   |                     `"90"`                     | Max polling attempts waiting for other <br>CI checks (raise this when a slow required check, e.g. e2e, gates the PR).  |
| wait-min-attempts  | string  |  false   |                     `"12"`                     |                                     Minimum polls before ci_green=true is allowed.                                     |
| wait-sleep-seconds | string  |  false   |                     `"10"`                     |                                           Seconds between polling attempts.                                            |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                                                                                                                                                                                                 DESCRIPTION                                                                                                                                                                                                                 |
|-----------------|----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|  ci-read-token  |  false   | Optional. Token for the read-only CI <br>poll, overriding the default of the <br>caller's GITHUB_TOKEN. Only needed as an <br>escape hatch when the caller cannot <br>grant `checks: read` / `statuses: read` (see the <br>job permissions below); pass a classic <br>PAT with `repo` scope or a <br>GitHub App token, both of which <br>can reach the Checks API. A <br>fine-grained PAT cannot, so do NOT <br>pass gh-access-token here.  |
| gh-access-token |   true   |                                                                                                                                                                                  GitHub PAT for approving PRs (must be different identity from PR author)                                                                                                                                                                                   |

<!-- AUTO-DOC-SECRETS:END -->

## Required caller permissions

Unless the caller supplies the optional `ci-read-token` secret, the calling job
must declare all four:

```yaml
jobs:
  auto-approve:
    permissions:
      contents: read
      pull-requests: write
      checks: read      # CI poll: /commits/:sha/check-runs
      statuses: read    # CI poll: /commits/:sha/status
    uses: loft-sh/github-actions/.github/workflows/auto-approve-bot-prs.yaml@auto-approve-bot-prs/v1
    secrets:
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

`checks` and `statuses` cannot be supplied by this workflow on your behalf. Per
GitHub, *"the `GITHUB_TOKEN` permissions passed from the caller workflow can be
only downgraded (not elevated) by the called workflow"*, and any permission the
caller omits defaults to `none`.

Omitting them does not fail loudly. The CI poll gets a 403, the action
default-denies, and the PR is never approved, while the check and the job both
still report success. If a release cut is waiting on that merge it will wait out
its full timeout. Look for `check-runs API failed` in the job log.

A caller with **no** `permissions:` block at all inherits the repository default
and is unaffected, provided that default is not restricted.

The approving PAT cannot be reused for the poll: fine-grained PATs cannot call
the Checks API at all. `ci-read-token` exists only for callers that cannot grant
the permissions and need to pass a classic PAT or App token instead.

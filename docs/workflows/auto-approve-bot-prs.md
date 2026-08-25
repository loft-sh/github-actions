# Auto-approve bot PRs

Reusable workflow that approves PRs from trusted bot accounts whose
title or branch matches a known safe pattern. Wraps the composite action
of the same name, adding a sparse checkout of this repo. It does not mint any
token: the approving PAT is supplied by the caller as the `gh-access-token`
secret.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE   | REQUIRED |                    DEFAULT                     |                                                                                                             DESCRIPTION                                                                                                              |
|--------------------|---------|----------|------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     auto-merge     | boolean |  false   |                    `false`                     |                                                                                    Merge the PR after approving it, <br>directly where possible.                                                                                     |
|    merge-method    | string  |  false   |                   `"squash"`                   |                                                                                                 Merge method (squash, merge, rebase)                                                                                                 |
| merge-when-blocked | boolean |  false   |                    `false`                     | Retry a refused merge through the <br>merge API so GitHub decides, rather <br>than gh's client-side check. Set this <br>when the merge token merges via <br>a ruleset bypass. Also requires the <br>approval to have been recorded.  |
|  trusted-authors   | string  |  false   | `"renovate[bot],loft-bot,github-actions[bot]"` |                                                                                              Comma-separated list of trusted bot logins                                                                                              |
| wait-max-attempts  | string  |  false   |                     `"90"`                     |                                                        Max polling attempts waiting for other <br>CI checks (raise this when a slow required check, e.g. e2e, gates the PR).                                                         |
| wait-min-attempts  | string  |  false   |                     `"12"`                     |                                                                                            Minimum polls before ci_green=true is allowed.                                                                                            |
| wait-sleep-seconds | string  |  false   |                     `"10"`                     |                                                                                                  Seconds between polling attempts.                                                                                                   |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                                                                                     DESCRIPTION                                                                                                      |
|-----------------|----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|  ci-read-token  |  false   |       Optional escape hatch for the read-only <br>CI poll when the caller cannot <br>grant `checks: read` / `statuses: read`. Classic PAT <br>with `repo` scope, or an App <br>token. Never gh-access-token.         |
| gh-access-token |   true   |                                        GitHub PAT for approving PRs (must be different identity from PR author). <br>Also used for merging when merge-token <br>is omitted.                                          |
|   merge-token   |  false   | Optional token used only for merging <br>when auto-merge is true. Defaults to <br>gh-access-token and needs a merge path <br>on the base branch — with <br>merge-when-blocked, that path is its ruleset <br>bypass.  |

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

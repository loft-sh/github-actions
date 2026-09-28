# Cleanup Backport Branches

Runs two branch cleanup policies using the pinned `fpicalausa/remove-stale-branches`
action. Product repositories call this workflow weekly and can request a manual
dry run.

| Policy | Eligible branches | Last tip commit age | Notice before deletion | Mutation gate |
|--------|-------------------|---------------------|------------------------|---------------|
| Backports | `backport/` branches without open PRs | 7 days | None | `dry-run: false` |
| Feature branches | Unprotected branches without open PRs, excluding `main`, `master`, `v` followed by a digit, `release-`, `release/`, and `backport/` branches | 90 days | 14 days | `dry-run: false` and repository variable `STALE_BRANCH_CLEANUP_ENABLED=true` |

Protected branches are excluded from both policies. Feature cleanup is read-only
unless the repository opts in. An unset variable or any value other than `true`
(case-insensitive) keeps reporting read-only. An explicit dry run overrides the variable for both policies.

The feature policy covers stale unmerged work too. It does not require a merged
PR. Age uses the tip commit's author date, not the branch's creation or push time.
The action first leaves a commit comment notifying the author, then waits at least
14 days before a later weekly run can delete the branch. Update or protect the
branch to retain it. Branches with unknown authors are skipped by the pinned action.
At most ten branches are marked stale or selected for deletion per policy per run.

After a live run deletes at least one branch, the workflow sends one Slack
notification with separate backport and feature branch lists and a link to the
workflow run. Dry runs and notice-only runs do not notify. The Slack webhook is
optional, so repositories without it continue cleanup without a notification.

Read the action logs to review candidates and skip reasons. Counts in a dry run
represent planned operations, not mutations. Before enabling feature cleanup,
review a manual dry run, confirm that the repository's default and long-lived
branches are protected or match the exemption pattern, and agree the policy with
branch owners. Remove the repository variable to return to reporting only.

The action does not recheck a branch tip immediately before deletion. The grace
period and open-PR exclusion reduce exposure but do not make deletion atomic with
concurrent pushes. Restoring a deleted branch requires its last commit SHA.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|  INPUT  |  TYPE   | REQUIRED | DEFAULT | DESCRIPTION  |
|---------|---------|----------|---------|--------------|
| dry-run | boolean |  false   | `false` | Dry run mode |

<!-- AUTO-DOC-INPUT:END -->

Callers must pass a boolean, for example `dry-run: true`, rather than the string
`'true'`. Use a boolean `workflow_dispatch` input and the typed `inputs` context.

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|      SECRET       | REQUIRED |                     DESCRIPTION                     |
|-------------------|----------|-----------------------------------------------------|
|  gh-access-token  |   true   | GitHub PAT with repo scope for <br>branch deletion  |
| slack-webhook-url |  false   |  Slack incoming webhook for deletion notifications  |

<!-- AUTO-DOC-SECRETS:END -->

Callers should map a dedicated Actions secret explicitly:

```yaml
secrets:
  gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
  slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_OPS_NOTIFICATIONS }}
```

# Backport

Creates backport PRs for merged PRs with `backport-to-<branch>` labels. The caller
runs from the trusted default branch on a push or a completed read-only PR signal workflow. The
workflow re-reads the PR from GitHub before any job receives a mutation token.

This is a new caller contract. Publish the workflow as `backport/v2`; keep
`backport/v1` unchanged until existing callers migrate. Publish the new
`resolve-pr-event/v1` action first. The action has not been released yet.

See the [resolver example](../../.github/actions/resolve-pr-event/README.md) for
push selection and matrix fanout. A push can merge more than one PR; use the
`events-json` matrix output, rather than the single-event output.

PR events cannot invoke the mutation jobs. A read-only `pull_request` workflow
with only the `labeled` activity type signals a default-branch `workflow_run`
consumer. It checks out no code and passes no artifact. The resolver reads the
completed run and associated merged PRs from GitHub, so labels added after merge
still trigger backports. Push selection handles merges, including those whose
original PR workflow was skipped. Omitting `closed` avoids a duplicate backport
run on merge. Fork code never runs in the privileged consumer.

For each selected envelope, restoration verifies the PR identity and merge SHA,
checks default-branch ancestry, and reads current labels. On push, restoration
also checks that the merge belongs to the original push range. It re-fetches only
the selected PR and uses a constant number of API requests without walking the
push range again.

| Stage | Trigger and reads | Mutations | Output and skip remedy |
|---|---|---|---|
| Select | Default-branch push; all commits in its range and associated PRs from GitHub | None | One event per merged PR. A commit with no PR, such as a direct push, is skipped with a warning that lists it; PRs merged in the same push still run. If a listed commit merged a PR, re-add its backport label to signal another run. |
| Resolve | Trusted default-branch caller; PR identity, merge and current labels from GitHub | None | Canonical merged PR event. Wrong branch or unmerged PR skips; merge first and run from the default branch. |
| Backport | Canonical event with current backport labels | Existing branch, PR and comment writes using the caller PAT | Existing cherry-pick logs and per-target failure comments. Remove an unwanted label or fix the reported conflict. |
| Link | Both modern and legacy producers have finished | Existing advisory Linear and PR links | Existing advisory output; missing Linear token skips linking. |

The resolver rejects forged identities, incomplete ranges and forced pushes.
Existing backport actions keep duplicate branch/PR checks and conflict comments.
Expected misses produce a warning or an empty selection; API failures fail the
job. Logs and job outputs remain the observability surface. No new service,
metric, alert or production policy is introduced.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE   | REQUIRED |                    DEFAULT                     |                                                                                                                                                                                                   DESCRIPTION                                                                                                                                                                                                   |
|-----------------|---------|----------|------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    docs-url     | string  |  false   |                                                |                                                              Optional link to this repo's backport <br>documentation. Added to the failure comment <br>so whoever hits it knows where <br>the process is written down. Omitted <br>when empty. An input rather than <br>a constant because this workflow is <br>shared with public repositories.                                                                |
|   fix-imports   | boolean |  false   |                    `false`                     |                                                      After the cherry-picks, run backport-fix-imports on <br>each backport branch: rewrite the repository's <br>own Go module paths to the <br>target line's major, resolve import-only conflicts, <br>and push a fix commit. For <br>repositories whose release lines sit on <br>an older module major.                                                        |
|  legacy-split   | boolean |  false   |                    `false`                     | Enable the pre-monorepo (<= v0.36) split/re-root backport <br>flow. When true this workflow empties <br>auto_backport_label_prefix so sorenlouv honors the caller's <br>.backportrc.json branchLabelMapping regex (which MUST be scoped to the monorepo era, >= v0.37), and a <br>companion job routes <= v0.36 targets <br>through backport-legacy-split. Requires subtree-prefix, oss-repo and <br>pro-repo.  |
|    oss-repo     | string  |  false   |                                                |                                                                                                                                                      OSS repo as owner/repo for legacy <br>OSS-side backport PRs. Required when legacy-split <br>is true.                                                                                                                                                       |
|    pr-event     | string  |  false   |                                                |                                                                                                                                                      Merged PR event JSON from resolve-pr-event <br>on a trusted default-branch push or <br>workflow_run.                                                                                                                                                       |
|    pro-repo     | string  |  false   |                                                |                                                                                                                                                 Pro repo as owner/repo for the <br>pro half of mixed legacy backports. <br>Required when legacy-split is true.                                                                                                                                                  |
| source-workflow | string  |  false   | `".github/workflows/pull-request-events.yaml"` |                                                                                                                                                           Read-only PR signal workflow path for <br>workflow_run callers. No artifacts are consumed.                                                                                                                                                            |
| subtree-prefix  | string  |  false   |                                                |                                                                                                                                            OSS subtree path in the monorepo, <br>e.g. staging/github.com/loft-sh/vcluster. Required when legacy-split is <br>true.                                                                                                                                              |

<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|     SECRET      | REQUIRED |                                                                DESCRIPTION                                                                 |
|-----------------|----------|--------------------------------------------------------------------------------------------------------------------------------------------|
| gh-access-token |   true   |                                                    GitHub PAT for creating backport PRs                                                    |
|  linear-token   |  false   | Linear API token for linking backport <br>PRs to their matching Linear sub-issue. <br>Optional; linking is skipped when not <br>provided.  |

<!-- AUTO-DOC-SECRETS:END -->

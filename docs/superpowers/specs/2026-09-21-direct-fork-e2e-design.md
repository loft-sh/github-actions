# Direct fork E2E command design

## Goal

Allow an authorized maintainer to run `/test-e2e` for a fork pull request
without a bot token, request comment, temporary label, or second event.

This is an alternative to the label-handoff drafts in `github-actions#271`,
`vcluster-pro#2465`, and `loft-enterprise#8249`. Those drafts remain unchanged
while this design is evaluated.

## Scope

The comparison initially has two draft pull requests:

- `loft-sh/github-actions`: add only the fork authorization and metadata needed
  by callers.
- `loft-sh/vcluster-pro`: call the existing Pro and OSS reusable E2E workflows
  directly for authorized fork requests.

The complete flow is tested in `vClusterLabs-Experiments/github-actions-test`
before the design is considered for `loft-enterprise`.

## Request flow

The `issue_comment` workflow continues to parse `/test-e2e`, validate its
filter, open the custom check, and authorize the commenter. Fork support is
opt-in. For a fork, the shared action additionally requires the commenter to
have `write`, `maintain`, or `admin` permission and returns `is-fork=true` plus
the pull request head SHA.

Same-repository requests keep the current `workflow_dispatch` path. Fork
requests use separate jobs in the trusted default-branch command workflow to
call the repository's existing reusable Pro and OSS workflows directly. Each
job checks out the exact head SHA captured when the comment was processed and
receives its custom check-run ID, filter, focus, and target selection.

## Security boundaries

- The workflow definition comes from the base repository's default branch.
- Only a commenter with write-level repository permission can authorize fork
  code to run.
- The called workflow checks out the captured fork commit with
  `persist-credentials: false`.
- The caller grants only the permissions and existing E2E secrets required by
  the selected suite.
- The reusable-workflow jobs set `cache-mode: read`. They may restore caches but
  cannot save or overwrite them, and that restriction propagates to nested
  reusable workflows.
- The custom check is attached to the captured SHA and is always completed,
  including preparation or suite failures.

The maintainer's command is the approval event. This design does not use
GitHub's native fork-run approval screen because the run starts from
`issue_comment`, not `pull_request`.

## Shared action contract

`comment-triggered-check` gains an opt-in `allow-forks` input. When false, fork
behavior remains unchanged. When true, `start` performs a repository permission
lookup for fork requests and returns:

- `is-fork`: whether the pull request head belongs to another repository.
- `head-sha`: the immutable commit the suite must test.
- `head-ref` and `base-ref`: existing pull request metadata used by current
  callers.

No queue or resolver modes, bot identity, label name, or bot token are added.
The permission and fork branches remain in the tested shell implementation,
not caller YAML.

## vcluster-pro workflow changes

`e2e-command.yaml` keeps preparation and same-repository dispatch intact. It
adds fork-only reusable-workflow jobs for Pro and OSS, gated by the parsed
target. The existing E2E workflows gain `workflow_call` inputs needed to run an
exact SHA and finish the custom check. Empty selections remain neutral for
command runs.

The workflow contract marker remains relevant only to same-repository
`workflow_dispatch`, where the pull request branch supplies its own workflow
definition.

## Error handling

Malformed commands and unauthorized commenters use the existing refusal
comment. A fork permission lookup failure refuses the request with a friendly,
retryable message. A selected fork job that cannot start or complete closes its
custom check as failed or neutral according to the existing command-run rules;
no check remains pending.

## Validation

- Add Bats coverage for fork opt-in, write-level authorization, denial, API
  failure, and unchanged default refusal.
- Run the complete `comment-triggered-check` Bats suite and ShellCheck.
- Add workflow contract tests for fork target routing, exact-SHA checkout,
  explicit secret forwarding, check completion, and read-only cache mode.
- Run actionlint and zizmor on changed workflows.
- In the experiments repository, open a real pull request from a personal fork,
  issue `/test-e2e` as a maintainer, and verify the direct reusable workflow
  runs the captured fork SHA without requiring a repository secret.

## Comparison decision

Prefer this design over the label handoff only if the integration test works
and the production diffs are materially smaller and easier to review. If it is
selected, port the caller pattern to `loft-enterprise`; otherwise keep the
existing drafts.

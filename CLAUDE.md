# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build/Lint/Test Commands
- Run all tests: `make test`
- Test semver-validation: `make test-semver-validation`
- Test linear-pr-commenter: `make test-linear-pr-commenter`
- Test linear-release-sync: `make test-linear-release-sync`
- Test publish-helm-chart: `make test-publish-helm-chart` (requires mikefarah/yq on PATH)
- Build linear-release-sync binary: `make build-linear-release-sync`
- Lint workflows: `make lint` (requires actionlint and zizmor)

## Code Style Guidelines
- See [docs/CONVENTIONS.md](docs/CONVENTIONS.md) for pipeline constraints and conventions
- Follow GitHub Actions YAML best practices
- Use descriptive names for action inputs, outputs, and steps
- Document each action with clear descriptions and examples
- Maintain backward compatibility when updating actions
- Use semantic versioning for action releases
- Keep actions focused on a single responsibility
- Use input validation and provide helpful error messages

## Testing Reusable Workflows

A unit-testable script + bats suite can't cover a `workflow_call` reusable workflow
end-to-end: both `github.workflow_sha` and `github.workflow_ref` resolve to the
caller's context in `workflow_call`, so sparse-checkout of the reusable workflow's
own repo doesn't work. Keep non-trivial reusable-workflow logic inline in the YAML
and cover scenarios via a dedicated e2e repo instead.

Pattern (see `auto-approve-bot-prs.yaml` + `vClusterLabs-Experiments/auto-approve-e2e`):

1. **Keep the in-repo smoke test** (`test-<workflow>.yaml`) — calls the workflow
   with GITHUB_TOKEN, asserts the skip-path stays green. Fast signal on every PR.
2. **Add a scenario matrix in a dedicated e2e repo** under
   `vClusterLabs-Experiments/`. One caller workflow uses `@main`. An orchestrator
   (`workflow_dispatch` + weekly cron) creates real PRs covering every decision
   branch, waits for the caller to finish, and asserts:
   - `conclusion ∈ {success, skipped, neutral}` — the **never-hard-fail invariant**
     (advisory workflows must not block caller CI)
   - decision-table outputs (`eligible=true|false`) match expectations
3. **Gotcha: GITHUB_TOKEN-created PRs don't trigger `pull_request` events for
   other workflows.** The orchestrator needs a PAT (`GH_ACCESS_TOKEN`) to open
   PRs that actually fire the caller workflow.

Never-hard-fail enforcement for advisory workflows (approval, notifications):

- `continue-on-error: true` on the job (final safety net)
- every shell step catches its own errors and exits 0 (`::notice::` / `::warning::`
  instead of `::error::`)
- pre-empt known failure modes in external actions before calling them (e.g.
  check PR author vs approver identity before calling hmarr's auto-approve,
  which otherwise `setFailed`s on the 422 self-review error)

## Release Process

Actions use per-action tags (e.g. `semver-validation/v1`, `linear-release-sync/v1`).

### YAML-only / Node.js actions (semver-validation, release-notification, etc.)
- Update code and commit changes
- Tag the release: `git tag -f <action-name>/v1`
- Push tag: `git push origin <action-name>/v1 --force`

### Go actions with pre-built binaries (linear-release-sync)
These actions download a pre-built binary from a GitHub release at runtime.
- **New version**: push a new tag (`git tag linear-release-sync/v1 && git push origin linear-release-sync/v1`) — triggers `release-linear-release-sync.yaml` automatically
- **Update existing version**: force-pushing a tag does NOT trigger workflows — use `workflow_dispatch` instead: `gh workflow run release-linear-release-sync.yaml -f tag=linear-release-sync/v1`

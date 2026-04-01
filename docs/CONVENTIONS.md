# Pipeline Infrastructure Constraints and Conventions

Binding constraints for all reusable pipeline logic in `loft-sh/github-actions`.
Changes to this document require a PR with team review.

## How Pipeline Logic is Expressed

Three tiers based on complexity:

| Pattern | When to use | Example |
|---|---|---|
| **YAML-only composite** | Thin glue wiring inputs to third-party actions, no custom logic | `release-notification` |
| **Compiled action (Go/Node.js)** | Business logic, API calls, data transformation | `linear-pr-commenter` (Go), `semver-validation` (Node.js) |
| **Reusable workflow** | Cross-repo orchestration of multiple jobs | `backport.yaml`, `actionlint.yaml` |

**Key rule:** Business logic (branching, loops, parsing, API calls) MUST live in
source files, not inline YAML `run:` blocks. YAML is glue only.

## Supported Languages

Language choice should be made on a case-by-case basis depending on action
requirements. The table below captures current status and guidance:

| Language | Status | Notes |
|---|---|---|
| **Go** | Supported | Org primary language. Used by `linear-pr-commenter`. |
| **TypeScript** | Preferred for actions | For `runs.using: node*` actions. Preferred over plain JS. Used by `semver-validation`. |
| **Python** | Supported | Well-represented in AI training data, good for AI-assisted development. Adds runtime dependency overhead — use when it fits the problem best. |
| **Bash** | Glue only | Scripts under ~50 lines. Must pass shellcheck. |

> **Note:** Evaluate [Dagger](https://dagger.io/) as a potential standardization
> layer — tracked in the DEVOPS-595 Linear issue.

## Fork and Branch Compatibility

- Explicit `permissions` at job level (least privilege).
- `persist-credentials: false` on all checkouts.
- Fork PRs have no secrets access — actions must skip gracefully or use a
  fork-detection guard:
  ```yaml
  if: github.event.pull_request.head.repo.full_name == github.repository
  ```
- Secrets via `env:` preferred over `with:` where possible.
- No hardcoded branch names in reusable workflows.

## Testability Requirements

### Unit tests

- Every action with business logic MUST have unit tests runnable locally.
- Makefile target: `test-<action-name>`.
- CI workflow: `.github/workflows/test-<action-name>.yaml` with `paths` filter
  scoped to the action's directory.
- Tests must not require real API tokens or network access.
- YAML-only composites are validated by actionlint + zizmor (no unit tests needed for now).
- Testing frameworks: **vitest** for TypeScript, **uv + pytest** for Python,
  standard `go test` for Go, **[bats](https://github.com/bats-core/bats-core)**
  for Bash scripts. CI uses
  [`bats-core/bats-action`](https://github.com/bats-core/bats-action); locally
  install bats with your package manager:
  ```bash
  # macOS
  brew install bats-core

  # Ubuntu / Debian
  sudo apt-get install bats

  # Arch Linux
  sudo pacman -S bats
  ```

### Integration tests

- For actions with complex branching logic or external action interactions,
  use the dedicated test repo:
  [`vClusterLabs-Experiments/github-actions-test`](https://github.com/vClusterLabs-Experiments/github-actions-test).
- Reference integration test results in the PR.
- Integration tests are useful when unit tests alone cannot exercise the full
  workflow (e.g., cross-repo dispatch, branch protection rules).

## Security Checklist

Every PR that adds or modifies an action must verify:

- [ ] `persist-credentials: false` on all checkout steps
- [ ] Explicit job-level `permissions` (least privilege)
- [ ] All action references pinned by SHA (tag in comment for Renovate)
- [ ] actionlint + zizmor clean (`make lint`)
- [ ] Fork PRs handled (skip gracefully or guard on repo match)

CodeQL is enabled on `vcluster`, `vcluster-pro`, and `loft-enterprise` and will
flag additional security issues in those repos.

> **Note:** Some action runs require manual approval (e.g., runs triggered by
> fork PRs or workflows referencing environments with protection rules).

## Directory Structure and Versioning

Actions live under `.github/actions/<action-name>/`. Each action is versioned
independently with `<action-name>/v<N>` tags:

```bash
git tag -f <action-name>/v1
git push origin <action-name>/v1 --force
```

Callers reference actions pinned by SHA with the tag in a comment so Renovate
can track updates:

```yaml
uses: loft-sh/github-actions/.github/actions/<action-name>@<commit-sha> # <action-name>/v1
```

Maintainers reserve the right to update the `v<N>` tag pointer at any time when
a new version is released, unless Renovate is configured to handle the upgrade
for a specific caller.

Reusable workflows live under `.github/workflows/` and are referenced the same
way — pinned by SHA with a tag comment.

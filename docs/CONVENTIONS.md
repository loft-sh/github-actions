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

| Language | Status | Notes |
|---|---|---|
| **Go** | Preferred | Org primary language. Used by `linear-pr-commenter`. |
| **Node.js** | Supported | For `runs.using: node*` actions. Used by `semver-validation`. |
| **Bash** | Glue only | Scripts under ~50 lines. Must pass shellcheck. |
| **Python** | Not supported | No existing patterns, adds runtime dependency overhead. |

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

- Every action with business logic MUST have unit tests runnable locally.
- Makefile target: `test-<action-name>`.
- CI workflow: `.github/workflows/test-<action-name>.yaml` with `paths` filter
  scoped to the action's directory.
- Tests must not require real API tokens or network access.
- YAML-only composites are validated by actionlint + zizmor (no unit tests needed for now).

## Security Checklist

Every PR that adds or modifies an action must verify:

- [ ] `persist-credentials: false` on all checkout steps
- [ ] Explicit job-level `permissions` (least privilege)
- [ ] All action references pinned by SHA (tag in comment for Renovate)
- [ ] actionlint + zizmor clean (`make lint`)
- [ ] Fork PRs handled (skip gracefully or guard on repo match)

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

Reusable workflows live under `.github/workflows/` and are referenced the same
way — pinned by SHA with a tag comment.

# Claude Code Review

Runs Claude-powered code review on same-repository pull requests. Both the caller
and this reusable workflow must check that the head repository equals the base
repository before passing the API key. Fork PRs skip review. The job grants only
`contents: read` and `pull-requests: write`; it does not build or run PR scripts.

Callers should use `pull_request`. During the transition, legacy
`pull_request_target` callers are also accepted for same-repository PRs. A
separate inventory tracks caller migration.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->
No inputs.
<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|      SECRET       | REQUIRED |                  DESCRIPTION                  |
|-------------------|----------|-----------------------------------------------|
| anthropic-api-key |   true   | Anthropic API key for Claude Code <br>Review  |

<!-- AUTO-DOC-SECRETS:END -->

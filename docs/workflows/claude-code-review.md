# Claude Code Review

Runs Claude-powered code review on pull requests.

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

## Session caps

This workflow sets conservative Claude Code session caps
(`CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`, `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION`)
so unattended reviews fail safe instead of burning budget on a runaway loop.
Callers inherit them automatically. See
[Claude Code CI session caps](../claude-code-ci-caps.md).

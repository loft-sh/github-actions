# Claude

Runs the Claude Code agent for trusted member, owner, or collaborator mentions. Pull request mentions run only when the head and base repositories match. Mentions on fork pull requests are skipped before the agent receives its secret.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->
No inputs.
<!-- AUTO-DOC-INPUT:END -->

## Secrets

<!-- AUTO-DOC-SECRETS:START - Do not remove or modify this section -->

|      SECRET       | REQUIRED |                 DESCRIPTION                  |
|-------------------|----------|----------------------------------------------|
| anthropic-api-key |   true   | Anthropic API key for Claude Code <br>agent  |

<!-- AUTO-DOC-SECRETS:END -->

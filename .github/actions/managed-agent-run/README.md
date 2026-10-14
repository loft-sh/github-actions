# Managed agent run

Starts one run of a Claude Managed Agents deployment, looked up by name, and returns
the run and session IDs. Use it when a CI event should wake an agent right away
instead of waiting for the deployment's own schedule. The first caller is the
release-candidate CVE scan, which starts the `scheduled-routines-cve-remediation`
routine in `loft-sh/ai-agents` after `linear-cve-summary` posts its summary.

The action only starts the run. It does not wait for the session to finish; the
agent delivers its own output (pull requests, Linear or Slack posts), and the
session is visible in the Anthropic Console.

The action is advisory. A missing key, an unknown or ambiguous deployment name,
and any API failure produce a GitHub warning and exit successfully. Callers should
also set `continue-on-error: true` and keep it in a job no release job needs.

Set `enabled: false` to skip every API call. Set `dry-run: true` to resolve the
deployment by name and log it without starting a run.

## Usage

```yaml
- name: Start CVE remediation
  continue-on-error: true
  uses: loft-sh/github-actions/.github/actions/managed-agent-run@managed-agent-run/v1
  with:
    anthropic-api-key: ${{ secrets.ANTHROPIC_OPS_SERVICES_API_KEY }}
    deployment-name: scheduled-routines-cve-remediation
    enabled: ${{ vars.CVE_REMEDIATION_ENABLED == 'true' }}
```

The key must belong to the Anthropic workspace that holds the deployment. A
deployment run replays the deployment's own initial message, so the agent decides
what to work on; the action passes no input.

## API

- `GET /v1/deployments?beta=true` (paginated with `next_page`) to find the
  deployment by exact name. Zero or several matches skip with a warning.
- `POST /v1/deployments/{id}/run?beta=true` to start the run.

Both send `anthropic-beta: managed-agents-2026-04-01`. `ANTHROPIC_API_URL`
overrides the base URL for tests.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT       |  TYPE  | REQUIRED |  DEFAULT  |                                                  DESCRIPTION                                                  |
|-------------------|--------|----------|-----------|---------------------------------------------------------------------------------------------------------------|
| anthropic-api-key | string |  false   |           |                       Anthropic API key of the workspace <br>that holds the deployment                        |
|  deployment-name  | string |   true   |           |              Name of the deployment to run, <br>for example scheduled-routines-cve-remediation                |
|      dry-run      | string |  false   | `"false"` |                     Resolve the deployment by name and <br>log it without starting a run                      |
|      enabled      | string |  false   | `"true"`  | Kill switch. Explicit falsey values skip <br>every API call; unrecognised values warn <br>and remain enabled  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT   |  TYPE  |                                 DESCRIPTION                                  |
|------------|--------|------------------------------------------------------------------------------|
|   run-id   | string |   ID of the started deployment run; <br>empty when skipped or on failure     |
| session-id | string | ID of the session the run <br>started; empty when skipped or on <br>failure  |

<!-- AUTO-DOC-OUTPUT:END -->

## Tests

```bash
make test-managed-agent-run
```

The suite runs the script against a local fake API and covers the started run,
pagination, the kill switch, a missing key, dry run, unknown and ambiguous names,
API failures, a run without a session, and unrecognised boolean inputs.

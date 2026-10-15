# Workflow IOC sweep

Sweep every repository of one or more GitHub organizations for indicators of a
malicious-workflow campaign, such as GhostAction: a workflow pushed with a stolen
maintainer credential that posts CI secrets to an attacker. Built for DEVOPS-1665.

Indicators are data. Each campaign is one JSON file under `iocs/`; a new campaign
needs a new file, not new code. `iocs/ghostaction.json` is the default.

## Checks

| Check | Reads | Catches |
|---|---|---|
| `registry` | `repos/{repo}/actions/workflows` | A payload workflow that ran from any branch, including one whose file or branch was deleted later |
| `history` | Blobless bare clone of every branch and tag | Payload commit subjects and workflow file paths anywhere in history; endpoints in `.github/` diffs since `history_since` |
| `audit` | Organization audit log, `workflows.created_workflow_run` | Payload workflow runs by name over the last `audit-days` days |

Names and subjects match exactly, ignoring case and whitespace. File names match
on the basename under `.github/workflows/`, with `.yml` and `.yaml` treated alike.
Endpoints match as literal substrings.

What it cannot see: who pushed a commit more than 7 days ago (GitHub keeps git
events in the audit log for 7 days), and a pushed branch that never ran and was
deleted before the sweep.

## Exit codes and result

| Exit | `result` | Meaning |
|---|---|---|
| 0 | `clean` | Every repository swept, no indicator |
| 1 | `indicator` | At least one indicator; errors may also be present |
| 2 | `error` | No indicator, but the sweep is incomplete (clone, API or indicator-file failure) |

A registry 404 (Actions disabled, or a security-advisory fork) is not an error:
nothing can have run there. The JSON report lists every finding and error, and
the step summary renders both as tables.

## Indicator file

```json
{
  "campaign": "GhostAction",
  "references": ["https://..."],
  "history_since": "2025-08-01",
  "workflow_files": ["security-audit.yml"],
  "workflow_names": ["Security Audit"],
  "commit_messages": ["Add Github Actions Security workflow"],
  "endpoints": ["193.32.204.199", "/api/workflow/receive"]
}
```

## Token

A GitHub App installation token per organization, read-only:

| Permission | Level | Used for |
|---|---|---|
| Repository `contents` | read | clone every branch and tag |
| Repository `actions` | read | list registered workflows |
| Repository `metadata` | read | list repositories |
| Organization `administration` | read | audit log, only when `audit-days` is above 0 |

Install the App on all repositories. The token reaches git through an
`http.extraheader` in the environment, never in a URL or on disk.

## Usage

`.github/workflows/workflow-ioc-sweep.yaml` in this repository runs it weekly for
`loft-sh` and `vClusterLabs-Experiments`, gated by the repository variable
`WORKFLOW_IOC_SWEEP_ENABLED`. It posts nowhere; a red run and the report artifact
are the signal.

```yaml
- uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
  id: app-token
  with:
    client-id: ${{ vars.WORKFLOW_IOC_SWEEP_APP_CLIENT_ID }}
    private-key: ${{ secrets.WORKFLOW_IOC_SWEEP_APP_PRIVATE_KEY }}
    owner: loft-sh
- uses: loft-sh/github-actions/.github/actions/workflow-ioc-sweep@workflow-ioc-sweep/v1
  with:
    github-token: ${{ steps.app-token.outputs.token }}
    owners: loft-sh
```

Run it locally with your own `gh` login:

```bash
python3 .github/actions/workflow-ioc-sweep/src/sweep.py \
  --owners loft-sh vClusterLabs-Experiments --audit-days 8 --include-archived
```

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT     |  TYPE  | REQUIRED |          DEFAULT          |                                                                   DESCRIPTION                                                                    |
|---------------|--------|----------|---------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
|  audit-days   | string |  false   |           `"8"`           |                Days of organization audit-log workflow runs <br>to check, counting back from today; <br>0 skips the audit check                  |
| github-token  | string |   true   |                           | Token that can list and clone <br>every repository, read Actions workflows and, <br>for audit-days above 0, read the <br>organization audit log  |
| history-since | string |  false   |                           |             Start date (YYYY-MM-DD) for the endpoint <br>scan of .github/ diffs; defaults to <br>the indicator file's history_since              |
|   iocs-file   | string |  false   |                           |                                     Indicator JSON file; defaults to the <br>bundled GhostAction indicators                                      |
|     jobs      | string |  false   |           `"8"`           |                                                          Repositories swept in parallel                                                          |
|    owners     | string |   true   |                           |                                                   Whitespace-separated organizations to sweep                                                    |
|  report-path  | string |  false   | `"ioc-sweep-report.json"` |                                                          Where to write the JSON report                                                          |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT    |  TYPE  |                             DESCRIPTION                             |
|-------------|--------|---------------------------------------------------------------------|
| report-path | string |                       Path of the JSON report                       |
|   result    | string | clean, indicator, or error (sweep incomplete without an indicator)  |

<!-- AUTO-DOC-OUTPUT:END -->

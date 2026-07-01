# Release Branch Code Freeze

Applies or lifts a temporary code freeze on a release branch by managing a
GitHub repository ruleset with the "Restrict updates" rule. During the freeze
only a bypass team can merge into the branch (a PR merge counts as an update, so
everyone else is blocked); lifting the freeze disables the ruleset so the branch
returns to its standing rules.

One reusable ruleset per repo (default name `release-branch-code-freeze`) is
re-pointed at the branch being released, so only that branch is frozen while
other release lines keep their normal rules. Uses the GitHub CLI (`gh`),
pre-installed on hosted runners.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT      |  TYPE  | REQUIRED |  DEFAULT   |                                                                     DESCRIPTION                                                                     |
|----------------|--------|----------|------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
|     branch     | string |  false   |            |                           Release branch to freeze or unfreeze, <br>e.g. v0.36 or release-4.11. Required for <br>freeze.                            |
| bypass-team-id | string |  false   |            | Numeric GitHub team id allowed to <br>merge during the freeze (required for <br>freeze). Find it with: gh api <br>orgs/<org>/teams/<slug> --jq .id  |
|  enforcement   | string |  false   | `"active"` |              active | evaluate | disabled. evaluate <br>is a dry run that logs <br>would-be blocks without blocking. Default active.                |
|   operation    | string |   true   |            |                                               freeze (apply the code freeze) or unfreeze (lift it).                                                 |
|   repository   | string |   true   |            |                                                        Target repository in owner/name form.                                                        |
|  ruleset-name  | string |  false   |            |                                           Override the ruleset name. Default release-branch-code-freeze.                                            |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT   |  TYPE  |                              DESCRIPTION                              |
|------------|--------|-----------------------------------------------------------------------|
| ruleset-id | string | Id of the freeze ruleset that <br>was created, updated, or disabled.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

### Freeze when a release branch is cut

```yaml
name: Code freeze on release branch
on:
  create

permissions:
  contents: read

jobs:
  freeze:
    # `create` fires for every ref; only act on release branches.
    if: github.event.ref_type == 'branch' && startsWith(github.event.ref, 'v')
    runs-on: ubuntu-latest
    steps:
      - uses: loft-sh/github-actions/.github/actions/release-branch-freeze@release-branch-freeze/v1
        with:
          operation: freeze
          repository: ${{ github.repository }}
          branch: ${{ github.event.ref }}
          bypass-team-id: "16898535" # loft-sh/Eng-Tech-Leads
        env:
          GH_TOKEN: ${{ secrets.CODE_FREEZE_TOKEN }}
```

Run the first rollout with `enforcement: evaluate` to log who would be blocked
without blocking anyone, then switch to the default `active`.

### Unfreeze when the stable tag is cut

```yaml
name: Lift code freeze on stable tag
on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.0' # first stable release of a line

permissions:
  contents: read

jobs:
  unfreeze:
    runs-on: ubuntu-latest
    steps:
      - uses: loft-sh/github-actions/.github/actions/release-branch-freeze@release-branch-freeze/v1
        with:
          operation: unfreeze
          repository: ${{ github.repository }}
        env:
          GH_TOKEN: ${{ secrets.CODE_FREEZE_TOKEN }}
```

`unfreeze` disables the named ruleset, so it needs neither `branch` nor
`bypass-team-id`.

## Auth

`GH_TOKEN` must be set as an environment variable (not an input). It must be a
Personal Access Token or GitHub App token with **Administration: read and
write** on the target repository, because rulesets are administered at that
level. `secrets.GITHUB_TOKEN` cannot manage rulesets. The token does not need
org-admin scope: the freeze ruleset is repo-level.

The bypass team is referenced by numeric id (find it with
`gh api orgs/<org>/teams/<slug> --jq .id`), so the token needs no org-read
permission at run time.

## Enforcement modes

| Mode | Effect |
|---|---|
| `active` | Freeze is enforced: only the bypass team can merge. Default. |
| `evaluate` | Dry run: would-be blocks are logged in the repo's ruleset insights, nobody is blocked. Use for a first rollout. |
| `disabled` | Ruleset enforces nothing. This is the state `unfreeze` leaves it in. |

## Testing

```bash
make test-release-branch-freeze
```

Runs the bats suite in `test/` against `src/freeze.sh` with a stubbed `gh` on
`PATH`. The end-to-end ruleset behavior (non-bypass merge blocked, bypass merge
allowed) was validated against a throwaway repo in the
`vClusterLabs-Experiments` org.

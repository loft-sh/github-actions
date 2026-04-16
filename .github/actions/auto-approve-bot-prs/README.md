# Auto-approve bot PRs

Approves PRs from trusted bot authors whose title or branch matches a known
safe pattern, after all other CI checks pass. Never hard-fails the job --
every failure mode degrades to a notice-level skip.

Safe patterns: `chore(` / `chore:` titles, `fix(deps):` titles,
`backport/` / `renovate/` / `update-platform-version-` branches.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED |                    DEFAULT                     |                                            DESCRIPTION                                            |
|--------------------|--------|----------|------------------------------------------------|---------------------------------------------------------------------------------------------------|
|     auto-merge     | string |  false   |                   `"false"`                    |                              Enable GitHub auto-merge after approval                              |
|    github-token    | string |   true   |                                                | PAT used to read PR state, <br>approve, and enable auto-merge. Must NOT <br>match the PR author.  |
|    merge-method    | string |  false   |                   `"squash"`                   |                         Merge method for auto-merge (squash|merge|rebase)                         |
|  trusted-authors   | string |  false   | `"renovate[bot],loft-bot,github-actions[bot]"` |                            Comma-separated list of trusted bot logins                             |
| wait-max-attempts  | string |  false   |                     `"90"`                     |                       Max polling attempts waiting for other <br>CI checks                        |
| wait-sleep-seconds | string |  false   |                     `"10"`                     |                                 Seconds between polling attempts                                  |

<!-- AUTO-DOC-INPUT:END -->

## Usage

```yaml
- uses: loft-sh/github-actions/.github/actions/auto-approve-bot-prs@auto-approve-bot-prs/v1
  with:
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

## Testing

```bash
make test-auto-approve-bot-prs
```

Runs the bats suites in `test/` against the shell scripts in `src/`.

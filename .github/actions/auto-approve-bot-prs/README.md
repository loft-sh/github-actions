# Auto-approve bot PRs

Approves PRs from trusted bot authors whose title or branch matches a known
safe pattern, after all other CI checks pass. Never hard-fails the job --
every failure mode degrades to an annotated skip and exit 0.

Refusing to approve is annotated at **error** level, because it is a real
outcome that something downstream may be blocking on (a release cut waiting for
the bump PR to merge, for example). That raises an annotation only; the step
still exits 0, so the job conclusion and any required check stay green.

Safe patterns: `chore(` / `chore:` titles, `fix(deps):` titles,
`backport/` / `renovate/` / `update-platform-version-` branches.

## Signals treated as CI

Approval is blocked unless every non-self signal on the PR head resolves to
`success`, `skipped`, or `neutral`. The action polls both APIs GitHub uses
to surface CI:

- **Check-runs** (`/commits/:sha/check-runs`) — GitHub Actions and most
  GitHub Apps.
- **Commit statuses** (`/commits/:sha/status`) — legacy CI integrations
  such as Netlify, CircleCI, Travis. A `failure`/`error` state here blocks
  approval even when all check-runs are green.

Because external systems (Netlify in particular) can take a couple of
minutes to register their first `pending` signal, the action enforces a
`wait-min-attempts` floor before it is allowed to emit `ci_green=true`.
This prevents early approval against a PR that looks quiet simply because
slow external checks have not shown up yet.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED |                    DEFAULT                     |                                                                                                                                                                                                                                                                                                     DESCRIPTION                                                                                                                                                                                                                                                                                                      |
|--------------------|--------|----------|------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     auto-merge     | string |  false   |                   `"false"`                    |                                                                                                                                                                                                                                                                                       Enable GitHub auto-merge after approval                                                                                                                                                                                                                                                                                        |
|   ci-read-token    | string |  false   |                                                | Token for the read-only CI polling <br>(check-runs + commit statuses) only. Defaults to the caller's <br>GITHUB_TOKEN, which is what you want: <br>reading CI state needs no distinct <br>identity, and only the approval does, <br>because GitHub forbids self-approval. Do NOT <br>point this at the approving PAT <br>on a private repository: fine-grained PATs <br>cannot call the Checks API at <br>all (there is no Checks permission to grant), so polling would fail <br>every time and the action would <br>default-deny forever. The CALLER workflow must <br>grant `checks: read` and `statuses: read`.  |
|    github-token    | string |   true   |                                                |                                                                                                                                                                                                                                                          PAT used to read PR state, <br>approve, and enable auto-merge. Must NOT <br>match the PR author.                                                                                                                                                                                                                                                            |
|    merge-method    | string |  false   |                   `"squash"`                   |                                                                                                                                                                                                                                                                                  Merge method for auto-merge (squash|merge|rebase)                                                                                                                                                                                                                                                                                   |
|  trusted-authors   | string |  false   | `"renovate[bot],loft-bot,github-actions[bot]"` |                                                                                                                                                                                                                                                                                      Comma-separated list of trusted bot logins                                                                                                                                                                                                                                                                                      |
| wait-max-attempts  | string |  false   |                     `"90"`                     |                                                                                                                                                                                                                                                                                Max polling attempts waiting for other <br>CI checks                                                                                                                                                                                                                                                                                  |
| wait-min-attempts  | string |  false   |                     `"12"`                     |                                                                                                                                                                                                                                  Minimum polls before ci_green=true is allowed. <br>Prevents early approval while slow external <br>checks (e.g. Netlify) have not yet registered.                                                                                                                                                                                                                                   |
| wait-sleep-seconds | string |  false   |                     `"10"`                     |                                                                                                                                                                                                                                                                                           Seconds between polling attempts                                                                                                                                                                                                                                                                                           |

<!-- AUTO-DOC-INPUT:END -->

## Two tokens, on purpose

Approving needs a PAT, because GitHub forbids self-approval and the approver
identity must differ from the PR author. **Reading CI state does not.** The two
are split:

| Step | Token |
|------|-------|
| `check-pr-ready`, *Approve PR*, *Enable auto-merge* | `github-token` (PAT) |
| *Wait for other CI to pass* | `ci-read-token`, defaulting to `GITHUB_TOKEN` |

Do not point `ci-read-token` at the approving PAT on a private repository.
**Fine-grained PATs cannot call the Checks API at all** — there is no `Checks`
permission to grant, and the fine-grained permissions reference lists no
`/check-runs` endpoints. The poll would fail on every attempt and the action
would default-deny forever. This is not hypothetical: it stalled the `v0.36.1`
release cut for ~70 minutes (DEVOPS-1254).

Note that this misconfiguration is invisible on a **public** repository, where
`/check-runs` answers with no credentials at all. Working there proves nothing
about a private caller.

## Required caller permissions

The caller workflow must grant these. They cannot be added by this action or by
the reusable workflow that wraps it: per GitHub, *"the `GITHUB_TOKEN` permissions
passed from the caller workflow can be only downgraded (not elevated) by the
called workflow"*, and any permission the caller omits defaults to `none`.

```yaml
permissions:
  contents: read
  pull-requests: write
  checks: read      # CI poll: /commits/:sha/check-runs
  statuses: read    # CI poll: /commits/:sha/status
```

Omitting `checks`/`statuses` does not fail loudly. CI stays green, the job stays
green, and the PR is simply never approved.

## Usage

The `permissions:` block is part of the usage, not an optional extra. Copying
this snippet without it reproduces the silent no-approve failure described above.

```yaml
jobs:
  auto-approve:
    permissions:
      contents: read
      pull-requests: write
      checks: read      # CI poll: /commits/:sha/check-runs
      statuses: read    # CI poll: /commits/:sha/status
    steps:
      - uses: loft-sh/github-actions/.github/actions/auto-approve-bot-prs@auto-approve-bot-prs/v1
        with:
          github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

If the caller genuinely cannot grant `checks: read` (an org policy pinning the
default token, say), pass `ci-read-token` instead: a classic PAT with `repo`
scope, or a GitHub App token. Both can reach the Checks API. A fine-grained PAT
cannot, so `github-token` is never a valid value for it.

## Testing

```bash
make test-auto-approve-bot-prs
```

Runs the bats suites in `test/` against the shell scripts in `src/`.

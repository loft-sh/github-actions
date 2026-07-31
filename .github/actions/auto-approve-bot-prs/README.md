# Auto-approve bot PRs

Approves PRs from trusted bot authors whose title or branch matches a known
safe pattern, after all other CI checks pass. No API, parse, permission or
input-validation failure exits non-zero: each degrades to an annotated skip and
exit 0.

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

### Which attempt counts

GitHub keeps every attempt for a name on the same SHA — reruns, and each
concurrency-superseded run — so the poll picks one per name. It ranks by
**information content first, then recency**:

| rank | conclusion | meaning |
|------|------------|---------|
| 3 | not completed | verdict not in yet, wait |
| 2 | success, neutral, failure, timed_out, … | carries a verdict |
| 1 | skipped, cancelled | carries no verdict about the code |

Recency alone is not safe. A workflow that skips its expensive job on a no-op
PR-description edit publishes a `skipped` check-run named after the job that
already **failed** on that SHA, with a later `started_at` — so latest-wins would
pick `skipped`, count it green, and approve a PR whose suite failed. Ranking
keeps the failure. A genuine re-run that *succeeds* still clears it, because
success carries a verdict and recency then decides.

This is not a Checks API artifact and `filter=latest` does not help: that
dedupes within a check suite, and every run gets its own suite, so the API
faithfully returns all attempts.

### Cancelled checks

`cancelled` is neither a pass nor a failure. It is usually GitHub's
concurrency-group cancellation superseding a run, in which case a replacement
is on its way and the cancelled attempt should be ignored once the replacement
registers. So it is held rather than bailed on, and released two ways:

- **Superseded** — a non-completed check-run exists in a **newer check suite**
  than the cancelled one. A rerun is demonstrably in flight, so the wait
  continues until it registers (bounded by `wait-max-attempts`). Suite ids are
  monotonic, which is what makes "newer" observable without `actions: read`.
- **Final** — no newer suite is running. Past `wait-min-attempts` the
  cancellation is treated as real (a human pressed cancel) and approval is
  skipped.

Do not tie this to `wait-min-attempts` alone. A cancelled job queued behind a
long build in the same workflow cannot be replaced until that build finishes,
which is routinely minutes after the floor expires — the bail then discards a
rerun that was still coming. That stalled the `v0.34.7` cut
(vcluster-pro#2155): floor expired 12:49:45, replacement registered 12:51:41.

## Merging

With `auto-merge: true` the action tries a **plain merge first**, and uses
GitHub's auto-merge queue (`--auto`) only as a fallback.

By the time the merge step runs, every other check is already green and the PR
is approved, so there is normally nothing left for the queue to wait on.
`--auto` additionally requires the repository's `allow_auto_merge` setting,
which is invisible from here and silently turns the merge into a no-op when it
is off — and a merge that never happens strands whatever is waiting on it (the
`vcluster-release` orchestrator blocks on exactly this merge during a legacy
release cut).

`--auto` still has a job: a required check that registered *after* the CI wait
declared green legitimately refuses a merge right now but can complete later.
Queueing is the right answer there, so a refused plain merge degrades to it.

A PR that is approved but ends up merged by neither path is annotated at
**error** level, carrying both underlying `gh` errors, since this is the only
place that cause is knowable. Re-runs stay quiet: an already-merged PR is
benign, and a PR closed unmerged is a human decision.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED |                    DEFAULT                     |                                                                                                DESCRIPTION                                                                                                 |
|--------------------|--------|----------|------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     auto-merge     | string |  false   |                   `"false"`                    |                                                            Merge the PR after approving it, <br>directly where possible. See README "Merging".                                                             |
|   ci-read-token    | string |  false   |                                                | Token for the read-only CI poll <br>only; defaults to the caller GITHUB_TOKEN, <br>which needs `checks: read` and `statuses: read`. Never <br>the approving PAT. See README "Two <br>tokens, on purpose".  |
|    github-token    | string |   true   |                                                |                                                     PAT used to read PR state, <br>approve, and enable auto-merge. Must NOT <br>match the PR author.                                                       |
|    merge-method    | string |  false   |                   `"squash"`                   |                                                                                     Merge method (squash|merge|rebase)                                                                                     |
|  trusted-authors   | string |  false   | `"renovate[bot],loft-bot,github-actions[bot]"` |                                                                                 Comma-separated list of trusted bot logins                                                                                 |
| wait-max-attempts  | string |  false   |                     `"90"`                     |                                                                           Max polling attempts waiting for other <br>CI checks                                                                             |
| wait-min-attempts  | string |  false   |                     `"12"`                     |                             Minimum polls before ci_green=true is allowed. <br>Prevents early approval while slow external <br>checks (e.g. Netlify) have not yet registered.                              |
| wait-sleep-seconds | string |  false   |                     `"10"`                     |                                                                                      Seconds between polling attempts                                                                                      |

<!-- AUTO-DOC-INPUT:END -->

## Two tokens, on purpose

Approving needs a PAT, because GitHub forbids self-approval and the approver
identity must differ from the PR author. **Reading CI state does not.** The two
are split:

| Step | Token |
|------|-------|
| `check-pr-ready`, *Approve PR*, *Enable auto-merge* | `github-token` (PAT) |
| *Wait for other CI to pass* | `ci-read-token`, defaulting to `GITHUB_TOKEN` |

Do not point `ci-read-token` at the approving PAT.
**Fine-grained PATs cannot call the Checks API at all** — there is no `Checks`
permission to grant, and the fine-grained permissions reference lists no
`/check-runs` endpoints. The poll would fail on every attempt and the action
would default-deny forever. This is not hypothetical: it stalled the `v0.36.1`
release cut for ~70 minutes (DEVOPS-1254).

Note that a fine-grained PAT appears to work on a **public** repository, where
`/check-runs` answers with no credentials at all, so working there proved nothing
about a private caller. Do not extrapolate the reverse: `GITHUB_TOKEN` is scoped
by the `permissions:` block whatever the repository's visibility, so the grants
below are required either way.

## Required caller permissions

Unless the caller supplies `ci-read-token`, it must grant these itself. They
cannot be added by this action or by the reusable workflow that wraps it: per GitHub, *"the `GITHUB_TOKEN` permissions
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
    runs-on: ubuntu-latest
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

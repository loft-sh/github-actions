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

`gh pr merge` decides mergeability **client-side**: it reads `mergeStateStatus`
and refuses with "the base branch policy prohibits the merge" without calling
the merge API. That verdict describes the pull request, not the caller, so it
ignores the merge token's ruleset bypass — a token GitHub would let merge is
turned away before it can try. `merge-when-blocked: true` retries through
`PUT /pulls/{n}/merge` instead, which has no such gate. It passes `sha`, the
equivalent of `--match-head-commit`.

The setting grants no privilege, since every rule is still enforced server-side
and a token without a bypass is refused there too. It is opt-in because for a
token that *does* carry one, it decides whether the action merges only what CI
approved or merges past whatever that bypass covers.

The action carries the pull request head SHA from the triggering event through
the run. It checks that SHA once before polling CI and again after CI passes. If
Renovate or another actor updates the branch while an older run is still
polling, that run skips approval.

The post-CI check is deliberately narrower than the preflight. It rejects a
moved head or a definitive merge conflict, but does not repeat the approver
identity lookup and does not wait for transient `mergeable: null` metadata.
Those checks already passed before the CI wait, and repeating them here can
strand a release on an unrelated API blip after all CI has completed.

Both merge calls pass `--match-head-commit`. For a direct merge, GitHub checks
the SHA atomically when it merges, so that path can only land the commit this
run tested. For the `--auto` fallback, GitHub CLI forwards the SHA as
`expectedHeadOid` when it enables auto-merge, which guards enqueueing only.
GitHub can leave auto-merge enabled after a later push by an actor with write
permission; any eventual merge then relies on the repository's required checks
and stale-approval settings for the new head, not on this run's original SHA.

The approval is submitted immediately after the second head check, but the
approval action does not bind its review to that SHA. Repositories that require
approvals to be invalidated after a push must enforce that through their branch
protection or ruleset settings.

The merge step uses `merge-token` when supplied, otherwise it keeps the existing
behavior and uses `github-token`. This lets a caller approve with an identity
that differs from the PR author, then merge with an identity that has a path
through branch protection. The merge identity may match the PR author because
GitHub forbids self-review, not self-merge.

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

A successful queue is **not** a promise that the PR lands. Other refusals reach
the same fallback and need a human, not patience: a strict "must be up to date
with base" rule with no auto-update queues indefinitely; a conflict introduced by
a base commit landing during the CI wait (up to ~15 min at the default
90 × 10 s) needs the rebase `check-pr-ready.sh` asks for; and `allow_auto_merge`
being off makes the queue request itself the silent no-op this ordering exists to
avoid. So the queued warning names what to check rather than asserting the merge
will complete on its own.

Each merge call is retried **once** after a short sleep. By this point the run
has already made up to 90 CI polls, up to 10 mergeability polls and the approval
call, so secondary rate limiting is a live risk, and the two merge attempts would
otherwise fire back-to-back — one blip could take out both and escalate a
transient failure as though it were a policy refusal.

A PR that is approved but ends up merged by neither path is annotated at
**error** level, carrying both underlying `gh` errors, since this is the only
place that cause is knowable. Those two reasons are the diagnosis; the
branch-protection checklist that follows them applies only if they point at
policy rather than a transient API error. Re-runs stay quiet: an already-merged
PR is benign, and a PR closed unmerged is a human decision.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED |                    DEFAULT                     |                                                                                                  DESCRIPTION                                                                                                   |
|--------------------|--------|----------|------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     auto-merge     | string |  false   |                   `"false"`                    |                                                              Merge the PR after approving it, <br>directly where possible. See README "Merging".                                                               |
|   ci-read-token    | string |  false   |                                                |     Token for the read-only CI poll <br>only; defaults to the caller GITHUB_TOKEN, <br>which needs `checks: read` and `statuses: read`. Never <br>the approving PAT. See README "Tokens <br>by purpose".       |
|    github-token    | string |   true   |                                                |                                       PAT used to read PR state <br>and approve. Must NOT match the <br>PR author. Also used to merge <br>when merge-token is omitted.                                         |
|    merge-method    | string |  false   |                   `"squash"`                   |                                                                                       Merge method (squash|merge|rebase)                                                                                       |
|    merge-token     | string |  false   |                                                |                  Optional token used only to merge <br>when auto-merge is true. Defaults to <br>github-token. It may match the PR <br>author, but needs a merge path <br>on the base branch.                   |
| merge-when-blocked | string |  false   |                   `"false"`                    | Retry a refused merge through the <br>merge API, so GitHub decides instead <br>of gh's client-side mergeability check. Needed <br>when the merge token merges via <br>a ruleset bypass. See README "Merging".  |
|  trusted-authors   | string |  false   | `"renovate[bot],loft-bot,github-actions[bot]"` |                                                                                   Comma-separated list of trusted bot logins                                                                                   |
| wait-max-attempts  | string |  false   |                     `"90"`                     |                                                                             Max polling attempts waiting for other <br>CI checks                                                                               |
| wait-min-attempts  | string |  false   |                     `"12"`                     |                               Minimum polls before ci_green=true is allowed. <br>Prevents early approval while slow external <br>checks (e.g. Netlify) have not yet registered.                                |
| wait-sleep-seconds | string |  false   |                     `"10"`                     |                                                                                        Seconds between polling attempts                                                                                        |

<!-- AUTO-DOC-INPUT:END -->

## Tokens by purpose

Approving needs a PAT, because GitHub forbids self-approval and the approver
identity must differ from the PR author. Reading CI state does not. Merging may
need another identity when branch protection restricts pushes. The steps are
split:

| Step | Token |
|------|-------|
| `check-pr-ready`, `check-pr-after-ci`, *Approve PR* | `github-token` (PAT) |
| *Wait for other CI to pass* | `ci-read-token`, defaulting to `GITHUB_TOKEN` |
| *Merge PR* | `merge-token`, defaulting to `github-token` |

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

## Log safety

Everything this action reports is externally controlled: `gh`'s output is
GitHub's, check-run names and commit-status contexts belong to whoever posted
them, the authenticated login comes from the API, and `merge-method` comes from
the calling workflow. A bare CR in any of those is enough to forge an
annotation, because CR terminates a log line for the runner and a line starting
`::` is parsed as a workflow command.

So every such value goes through `safe`/`sanitize_for_log` from
`src/lib/log.sh` before it reaches a log line — one rule for the whole action,
rather than a per-field argument about which API fields are trustworthy. If
that lib is missing the scripts fail loudly instead of falling back to
unsanitized output, since a silent fallback would reopen every channel at once.

## Testing

```bash
make test-auto-approve-bot-prs
```

Runs the bats suites in `test/` against the shell scripts in `src/`.
Assertions that must be able to fail live in `test/assertions.bash`: a bare
`! grep` is inert under the `set -e` that bats runs test bodies with, so negative
assertions use `assert_no_match`. This applies to negated *helper functions* too,
not just inline `grep`.

# oss-commit-sync

Bidirectional per-commit sync between a monorepo subtree and a downstream OSS
repository. Replaces `subtree-mirror` (snapshot mirroring via `git subtree
split` + guarded force-push) with incremental diff replay:

- Each synced commit is produced by 3-way applying the source commit's diff,
  re-rooted between the subtree prefix and the OSS repo root. Author, date,
  and message are preserved verbatim; the committer is the CI identity.
- The two histories are linked by commit-message trailers, which are the only
  sync state (no marker refs, no map files):
  - `Monorepo-Commit: <sha>` on OSS commits created from monorepo commits
  - `Oss-Commit: <sha>` on monorepo commits created from OSS commits
- Cost is O(new commits) per run. `git subtree split` walked the full history
  every time and timed out; this walks only the range since the last trailer.
- Both branches are append-only. Nothing is ever force-pushed; every failure
  mode fails closed before pushing.

## Directions

### `direction: export` (monorepo subtree → OSS branch)

Replays every first-parent commit after the resume point that touches
`subtree-prefix` onto the OSS branch tip. The resume point is the newest
`Monorepo-Commit` trailer on the OSS branch. Commits carrying an `Oss-Commit`
trailer originated on OSS and are skipped (loop guard).

Safety mechanisms, in order:

1. **Divergence guard** — every OSS commit we did not create must already be
   absorbed into the monorepo (appear as an `Oss-Commit` trailer). Otherwise
   the run fails closed with `diverged=true` and the caller dispatches the
   import direction. Nothing is pushed.
2. **Diff replay** — an absorbed external commit is never reverted by a
   replayed company commit, because only that commit's own changes are
   applied (snapshot projection would rewrite the whole tree).
3. **Convergence assertion** — after replay, the OSS tip tree must equal the
   monorepo staging tree, or the run fails without pushing. `align-tree: true`
   instead appends one bot-authored snapshot commit that sets the OSS tree to
   the staging tree: the append-only escape hatch (used at migration to drop
   OSS-only producer workflows, or after manual reconciliation).

New release lines: when the branch does not exist on OSS, it is created from
the OSS commit corresponding to the monorepo branch point (found via trailers
on the OSS default branch), then the branch-only commits are replayed.

### `direction: import` (external OSS commits → PR branch)

Replays every first-parent OSS commit after the resume point that we did not
create onto a freshly rebuilt PR branch, re-rooted under `subtree-prefix`.
The resume point is the newest `Oss-Commit` trailer on the base branch. The
caller pushes the branch and opens/updates the sync PR.

- `exclude-paths` drops OSS-only paths (producer workflows) from every
  replayed diff. A commit whose diff becomes empty is skipped without a
  marker commit; the skip is re-derived deterministically on every run, so
  no `--allow-empty` commit needs to survive GitHub's rebase-merge.
- A conflicting external commit fails the 3-way apply loudly; the run exits
  non-zero with `conflict-sha` set and a clean worktree.
- The checkout must be at the base branch (`branch` input) with full history.

**The sync PR must be rebase-merged** (never squash), or per-commit
authorship and the trailers are destroyed on the base branch. Have the
automation enable auto-merge with rebase rather than trusting habit. If a
maintainer needs to fix up a sync PR, they must add new commits (without an
`Oss-Commit` trailer), never amend the replayed ones; amendments are caught
later by the export convergence assertion.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `direction` | yes | | `export` or `import` |
| `subtree-prefix` | yes | | Subtree path, e.g. `staging/github.com/loft-sh/vcluster` |
| `oss-repo` | yes | | Downstream repo as `owner/repo` |
| `branch` | yes | | Branch to sync (same name both sides) |
| `github-token` | yes | | Token with read (import) / write (export) access to the OSS repo |
| `oss-default-branch` | no | `main` | Anchor source for new release-line branches (export) |
| `seed-monorepo-commit` | no | | First-run resume point, paired with `seed-oss-commit` (export) |
| `seed-oss-commit` | no | | First-run anchor (export) / resume point (import) |
| `align-tree` | no | `false` | Append a snapshot alignment commit on tree drift (export) |
| `exclude-paths` | no | | Newline-separated OSS-root-relative paths to drop (import) |
| `pr-branch` | no | `automation/sync-from-oss-<branch>` | Local branch for replayed commits (import) |

## Outputs

| Output | Direction | Description |
|---|---|---|
| `pushed` | export | `true` when commits were pushed to the OSS branch |
| `diverged` | export | `true` when unabsorbed external commits blocked the run |
| `exported-count` | export | Commits created on the OSS branch |
| `oss-tip` | export | OSS branch tip after the run |
| `has-changes` | import | `true` when external commits were replayed |
| `replayed-count` | import | External commits replayed |
| `skipped-count` | import | Commits skipped as excluded-paths-only |
| `conflict-sha` | import | OSS commit that failed the 3-way apply |
| `pr-branch` | import | Branch holding the replayed commits |

## Usage

```yaml
# Export: on push to main/v* touching the subtree.
- uses: loft-sh/github-actions/.github/actions/oss-commit-sync@oss-commit-sync/v1
  id: sync
  with:
    direction: export
    subtree-prefix: staging/github.com/loft-sh/vcluster
    oss-repo: loft-sh/vcluster
    branch: ${{ github.ref_name }}
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}

# Import: on cron / divergence dispatch; caller pushes + opens the PR.
- uses: loft-sh/github-actions/.github/actions/oss-commit-sync@oss-commit-sync/v1
  id: import
  with:
    direction: import
    subtree-prefix: staging/github.com/loft-sh/vcluster
    oss-repo: loft-sh/vcluster
    branch: main
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
    exclude-paths: |
      .github/workflows/release.yaml
      .github/workflows/push-head-images.yaml
```

Requires `fetch-depth: 0` on the checkout: resume points and loop guards are
discovered by walking first-parent history for trailers.

## Migration from subtree-mirror

1. Merge a monorepo commit carrying `Oss-Commit: <current oss tip>` (seeds
   the import resume point).
2. First export run: pass `seed-monorepo-commit` (the monorepo commit whose
   staging tree matches that OSS tip) + `seed-oss-commit`, and
   `align-tree: true` so the producer workflows still present on OSS are
   deleted by the alignment commit. Every commit after that carries trailers
   and neither seed nor alignment is needed again.

## Testing

```bash
cd .github/actions/oss-commit-sync && bats test/
```

Fixtures are throwaway local repos; no network. The suite includes the
interleaving scenarios that break snapshot-based mirroring (silent revert of
external commits, revert/reapply churn, import reverting unexported company
changes) as regression tests.

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
   absorbed into the monorepo (appear as an `Oss-Commit` trailer) or be
   *benign*: touching only `exclude-paths`, or carrying a post-image already
   present in the subtree (the import skips both kinds without a trailer).
   Otherwise the run fails closed with `diverged=true` and the caller
   dispatches the import direction. Nothing is pushed.
2. **Diff replay** — an absorbed external commit is never reverted by a
   replayed company commit, because only that commit's own changes are
   applied (snapshot projection would rewrite the whole tree).
3. **Convergence assertion** — after replay, the OSS tip tree must equal the
   monorepo staging tree (ignoring `exclude-paths`, which are never
   mirrored), or the run fails without pushing. `align-tree: true` instead
   appends one bot-authored snapshot commit that sets the OSS tree to the
   staging tree — on ANY difference, excluded paths included: it is the
   explicit operator escape hatch, and at migration it is what deletes the
   OSS-only producer workflows and seeds the first trailer.

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
  no `--allow-empty` commit needs to survive GitHub's rebase-merge. Pass the
  same list to the export direction, whose guard and assertion ignore those
  paths.
- A patch that applies as a no-op (the same change already landed in the
  subtree) is likewise skipped instead of aborting the run; the export guard
  recognizes such commits as benign by comparing their post-image blobs.
- A conflicting external commit fails the 3-way apply loudly; the run exits
  non-zero with `conflict-sha` set and a clean worktree.
- The checkout must be at the base branch (`branch` input) with full history.

**Merge the sync PR with rebase, never squash.** Squashing destroys the
per-commit authorship of external contributions on the base branch, which is
the whole point of the replay. It does NOT corrupt the sync, though: OSS
history is append-only and already holds the real commits, and the state
self-heals — squashed-away trailers make the externals look unabsorbed, but
the export guard classifies them as benign (content present) and the next
import re-skips them as no-ops (regression-tested in
`test/squash-tolerance.bats`). The damage is limited to monorepo blame and
contributor credit, so treat rebase-merge as review policy rather than
wiring auto-merge (which some compliance postures disallow). If a maintainer
needs to fix up a sync PR, they must add new commits (without an
`Oss-Commit` trailer), never amend the replayed ones; amendments are caught
later by the export convergence assertion.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|        INPUT         |  TYPE  | REQUIRED |  DEFAULT  |                                                                                                                                       DESCRIPTION                                                                                                                                       |
|----------------------|--------|----------|-----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|      align-tree      | string |  false   | `"false"` |                             Export only: when the post-replay OSS <br>tree differs from the staging tree, <br>append one snapshot alignment commit instead <br>of failing. Append-only escape hatch; use <br>for migration or after manual reconciliation.                              |
|        branch        | string |   true   |           |                                                                                                           Branch to sync (same name on both repos, usually github.ref_name).                                                                                                            |
|      direction       | string |   true   |           |                                                                                        export (monorepo subtree -> OSS branch) or import (external OSS commits -> PR branch under the subtree).                                                                                         |
|    exclude-paths     | string |  false   |           | Newline-separated paths (relative to the OSS repo root) that are never <br>mirrored, e.g. producer workflows. Import drops <br>them from replayed diffs; export ignores <br>them in the divergence guard and <br>the convergence assertion. Pass the same <br>list to both directions.  |
|     github-token     | string |   true   |           |                                                                               Token with read (import) or write <br>(export) access to the OSS repo. <br>Used to build the remote URL; <br>never logged.                                                                                |
|  oss-default-branch  | string |  false   | `"main"`  |                                                                                                OSS default branch used to anchor <br>newly created release-line branches. Export only.                                                                                                  |
|       oss-repo       | string |   true   |           |                                                                                                          Downstream OSS repository as owner/repo, e.g. <br>loft-sh/vcluster.                                                                                                            |
|      pr-branch       | string |  false   |           |                                                                                 Import only: local branch the replayed <br>commits are created on. Defaults to <br>automation/sync-from-oss-<branch>.                                                                                   |
| seed-monorepo-commit | string |  false   |           |                                                               Monorepo commit to resume from when <br>the OSS branch has no Monorepo-Commit <br>trailer yet (first export run). Must be paired <br>with seed-oss-commit.                                                                |
|   seed-oss-commit    | string |  false   |           |                                                      OSS commit anchor for the first <br>run: paired with seed-monorepo-commit on export; <br>the import resume point when the <br>base branch has no Oss-Commit trailer <br>yet.                                                       |
|    subtree-prefix    | string |   true   |           |                                                                       Path of the subtree within this <br>repo, e.g. staging/github.com/loft-sh/vcluster. Requires a full-history <br>checkout (fetch-depth: 0).                                                                        |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT     |  TYPE  |                                            DESCRIPTION                                            |
|----------------|--------|---------------------------------------------------------------------------------------------------|
|  conflict-sha  | string |  Import: the OSS commit that failed <br>the 3-way apply, when the run <br>failed on a conflict.   |
|    diverged    | string |  Export: true when OSS has external <br>commits not yet absorbed and the <br>run failed closed.   |
| exported-count | string | Export: number of commits created on <br>the OSS branch (including an alignment commit, if any).  |
|  has-changes   | string |     Import: true when at least one <br>external commit was replayed onto the <br>PR branch.       |
|    oss-tip     | string |                          Export: the OSS branch tip after <br>the run.                            |
|   pr-branch    | string |                    Import: the local branch holding the <br>replayed commits.                     |
|     pushed     | string |                   Export: true when commits were pushed <br>to the OSS branch.                    |
| replayed-count | string |                           Import: number of external commits replayed.                            |
| skipped-count  | string |      Import: number of external commits skipped <br>because they touch only excluded paths.       |

<!-- AUTO-DOC-OUTPUT:END -->

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

# backport-legacy-split

Backport a merged **monorepo** commit into a **pre-monorepo** (`<= v0.36`)
release line.

This action exists for the vCluster setup where `vcluster-pro` is the monorepo —
pro code at the repo root, OSS code mirrored under
`staging/github.com/loft-sh/vcluster/` — while the legacy `v0.19`–`v0.36`
release branches predate that merge and still use the **old layout**: the pro
repo keeps pro code at root and pulls OSS via `go.mod`, and `loft-sh/vcluster`
keeps OSS code at root.

Because the layouts differ, a plain cherry-pick of a monorepo commit onto a
legacy branch is wrong: for an OSS change it would **recreate the `staging/`
tree** on the legacy branch instead of patching the real paths. This action
routes by the commit's changed paths instead.

> Boundary: `<= v0.36` uses this split flow; `>= v0.37` is the monorepo era and
> is propagated by the subtree mirror, not backported here.

## Routing

| Commit touches | Action |
| -- | -- |
| pro paths only (nothing under the prefix) | apply the whole diff onto the **pro repo** legacy branch (same root layout, no re-root) |
| the subtree prefix only | re-root the diff to OSS layout and open a backport branch/PR on the **OSS repo** |
| both | **two** backport branches/PRs, opened in parallel: OSS half → OSS repo, pro half → pro repo |

> Under `legacy-split`, sorenlouv is scoped to the monorepo era (`>= v0.37`), so
> it does **not** cover pro-only legacy backports — this action handles them.

The pro half of a mixed commit (and a pro-only commit) is
`git diff -- ':(exclude)<prefix>'`, so it **carries the root `go.mod` diff as-is**
(unrelated dependency bumps ride along).
The action does **not** compute the `loft-sh/vcluster` pin and **does not cut
releases or tags** — a human sequences the two merges and reconciles the pin.

## How the re-root works

`git diff --binary --relative=<prefix>/ <base> <head>` both **filters** the diff
to the subtree and **strips** the prefix in one step, yielding an OSS-rooted patch
that `git apply` lands on the OSS checkout. The trailing slash matches on a
component boundary (so a sibling module like `<prefix>-pro` can't leak in), and
`--binary` carries binary file changes (a plain diff emits an unappliable "Binary
files differ" placeholder). This is **not** `git subtree split` (used by
`subtree-mirror`), which re-roots full history and is the wrong tool for a single
backport.

## Diff range (any merge strategy)

The backport is the PR's own change set. When `pr-number` is set, the action
fetches the PR head (`refs/pull/<n>/head`, via `github-token`) and diffs
`merge-base(<commit>^1, <pr-head>)..<pr-head>` — exactly GitHub's "Files changed".

This is correct for **every** merge strategy. A squash flattens the commits and a
rebase replays them, but the PR head is unchanged, so its diff is the full PR
either way. Anchoring the merge base on the merge commit's **first parent**
`<commit>^1` also handles a true merge commit, whose *second* parent is the PR
head — `merge-base(<commit>, <pr-head>)` would collapse to the PR head and diff
nothing, while the first parent is the base side and gives the real fork point.
It **excludes base-branch drift** (the merge base is the stable fork point) and
does **not** depend on the mutable `pull_request.base.sha`. Using the merge
commit's own tree (`<commit>^..<commit>`) would instead capture only the *last*
commit of a rebase-merged PR — silently dropping the rest — which is why we diff
the PR head.

Without `pr-number` (standalone/test runs) it falls back to `<commit>^..<commit>`,
correct for a single-commit / squash case.

## Conflicts

Legacy code diverges from the monorepo, so patches will not always apply
cleanly. The patch is applied with `git apply --3way`; for that to produce real
conflict markers across two repos, the monorepo's object store is exposed to the
target checkout via an `objects/info/alternates` link (the re-rooted patch keeps
blob **content**, so `--3way` matches preimage blobs by SHA). On conflict the
markers are committed as-is and `<side>-conflicts=true` is emitted (parity with
the backport tool's `commitConflicts: true`). The PR is opened as a **draft** so
it can't be auto-merged with markers in it — `auto-approve-bot-prs` approves any
`backport/` PR, and committed markers read as valid (mergeable) content, so draft
is the state GitHub refuses to merge until a human resolves and marks it ready.

If `git apply --3way` fails outright (e.g. a file the patch changes was deleted
or renamed on the legacy branch, so its preimage isn't in the target index),
nothing is staged and the run **fails loudly** with an actionable error rather
than pushing an empty backport.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT      |  TYPE  | REQUIRED | DEFAULT  |                                                                                                                                                         DESCRIPTION                                                                                                                                                         |
|----------------|--------|----------|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     commit     | string |  false   |          |                                                                                       Monorepo merge commit to backport (the tip). <br>Names the backport branch; also the <br>diff HEAD in the fallback path. <br>Defaults to HEAD.                                                                                        |
|   create-pr    | string |  false   | `"true"` |                                                                                                                  true = open a PR per <br>pushed backport branch via gh. false <br>= push branches only.                                                                                                                    |
|  github-token  | string |   true   |          |                                                                                             Token with write access to both <br>repos and permission to open PRs. <br>Used to build push remotes and <br>by gh; never logged.                                                                                               |
|    oss-repo    | string |   true   |          |                                                                                                                                    OSS repository as owner/repo, e.g. loft-sh/vcluster.                                                                                                                                     |
|   pr-number    | string |  false   |          | Source PR number. When set, the <br>PR head is fetched from refs/pull/<n>/head <br>(via github-token) and the diff is merge-base(commit^1, pr-head)..pr-head <br>-- GitHub's 'Files changed', correct for <br>any merge strategy (squash, rebase, or merge commit). Omit (e.g. tests) <br>to fall back to commit^..commit.  |
|    pro-repo    | string |   true   |          |                                                                                              Pro repository as owner/repo, e.g. loft-sh/vcluster-pro. <br>Target for pro-only commits and the <br>pro half of a mixed commit.                                                                                               |
| subtree-prefix | string |   true   |          |                                                               Path of the OSS subtree within <br>the monorepo, e.g. staging/github.com/loft-sh/vcluster. Requires a <br>full-history checkout of the monorepo as <br>the working directory (fetch-depth: 0).                                                                |
| target-branch  | string |   true   |          |                                                                                               Legacy release branch to backport onto, <br>e.g. v0.35. Must exist on the <br>OSS repo (and, for mixed commits, the pro repo).                                                                                                |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT      |  TYPE  |                                                                               DESCRIPTION                                                                                |
|-----------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| backport-branch | string |                                                       The backport branch name pushed to <br>the target repo(s).                                                         |
|  comment-body   | string | Ready-to-post Markdown summarizing the backport PR <br>link(s) for this target; empty when <br>none were opened/found. Upsert as a <br>sticky comment on the source PR.  |
|  oss-conflicts  | string |                                                        true when the OSS half applied <br>with merge conflicts.                                                          |
|   oss-pr-url    | string |                                      URL of the OSS backport PR <br>opened this run (or the one already open); empty if <br>none.                                        |
|   oss-pushed    | string |                                                            true when an OSS backport branch <br>was pushed.                                                              |
|  pro-conflicts  | string |                                                        true when the pro half applied <br>with merge conflicts.                                                          |
|   pro-pr-url    | string |                                      URL of the pro backport PR <br>opened this run (or the one already open); empty if <br>none.                                        |
|   pro-pushed    | string |                                               true when a pro backport branch <br>was pushed (pro-only or mixed commits).                                                |
|      route      | string |                                                     Classification of the commit: pro-only | <br>oss-only | mixed.                                                       |

<!-- AUTO-DOC-OUTPUT:END -->

## Notes

- Backport branches use the `backport/` prefix so `auto-approve-bot-prs` and
  `cleanup-backport-branches` keep working.
- **Linear linking:** these PRs are **not** auto-linked to Linear sub-issues.
  `link-backport-prs` runs in the reusable workflow's `backport` job against the
  caller repo keyed on the source PR, and only matches sorenlouv-created PRs; it
  does not cover the cross-repo PRs this action opens. Cross-repo linking is a
  separate follow-up (see DEVOPS-1051); link these PRs manually for now.
- Re-runs are idempotent and safe for the conflicted-PR flow: once a PR is open
  for the head->base pair, a re-run leaves the branch **and** PR untouched, so a
  human's manual conflict resolution on that branch is never clobbered. The
  branch is (force-)created only when no PR exists yet (first run, or a leftover
  branch from a prior run whose PR creation failed).
- The `>= v0.37` / EOL allow-list guard lives in the **shared reusable
  `backport.yaml`**, not in this action.

## Tests

`bats` against local temporary repos (a monorepo plus bare legacy OSS and pro
remotes); pushes go to local bare repos, not the network:

```bash
bats .github/actions/backport-legacy-split/test
```

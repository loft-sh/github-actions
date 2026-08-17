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

## Prerequisites

The export pushes **directly** to the OSS default branch (the mirror is
maintained by automation, not by per-change PRs). On a protected public repo
that means the sync identity must be able to bypass **every** protection
targeting that branch — and there are usually two independent systems, both
of which must be satisfied:

1. **Repository and organization rulesets** — the identity must be a bypass
   actor on each ruleset that enforces `pull_request` on the branch. A
   **team** bypass actor only takes effect if that team has access to the
   repo; a team on the bypass list without repo access is silently inert. A
   **classic PAT** does not reliably inherit team bypass in all setups — if a
   team bypass won't apply, use a `RepositoryRole` bypass or a GitHub App
   (`Integration`) bypass actor.
2. **Legacy branch protection** (if still present alongside rulesets) — the
   identity must be in both the "restrict who can push" allowlist and the
   "allow specified actors to bypass required pull requests" list. Editing
   `bypass_pull_request_allowances` via the API is **replace** semantics:
   read the current list and append, or you will drop existing actors.

There is no reliable pre-push check for this: server-side rulesets are not
evaluated on `git push --dry-run`, and a token with write access can still be
blocked. The only authoritative validation is an actual push plus the repo's
**Rules → Rule Insights** view, which shows, per ruleset, whether the actor
bypassed. When the push is rejected, this action fails with an actionable
error and sets `push-rejected=true`.

**Change-management note:** because the OSS repo is a downstream mirror of a
source-of-truth monorepo (every commit is reviewed upstream before it is
republished here), a scoped automation identity bypassing PR on the mirror is
a documentable control exception, not an unreviewed production change. Record
it as such (identity scoped, token rotated, mechanism deterministic and
trailer-audited) if the mirror repo is in scope for change-management review.

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

   Because that overwrite deletes whatever OSS holds and the monorepo does not,
   the alignment commit demands stronger absorption evidence than an ordinary run.
   If an external counts as absorbed only by an `Oss-Commit` line *outside* the
   block git's own trailer parser reads, and its content is not in the subtree, the
   run fails instead of aligning. Ordinary exports accept that line, which is what
   rescues a squash-orphaned trailer, but it cannot tell "never absorbed" from
   "absorbed, then superseded", and only one of those is safe to flatten. The check
   sits at the alignment commit itself, so a run whose trees already agree is
   unaffected. `loose-absorption=true` reports that combination, weak evidence and
   absent content, which is narrower than "a trailer was orphaned": a loose record
   whose content the import did apply is not flagged, because nothing could be lost.
   Use `direction: health` to find orphaned trailers in general.

   The check covers an existing OSS branch. The new-release-line path below builds
   its anchor from the default branch's trailers instead of running the divergence
   guard, so alignment there is ungated, as it was before this check existed.

   Do not dispatch the import direction on it. The anchor comes from the same
   whole-message scan, so it already reaches past those commits and the import has
   nothing to replay. To clear it, confirm per commit whether the content really
   was absorbed. If it was and a later commit superseded it, record that where
   git's parser reads it, i.e. an empty commit whose message ends with a paragraph
   containing only `Oss-Commit: <sha>`. If it was never absorbed, do not add a
   trailer: apply that commit's changes under the subtree prefix and commit them,
   which leaves alignment nothing to delete. `seed-oss-commit` cannot help, because
   it only ever moves the anchor forward.

New release lines: when the branch does not exist on OSS, it is created from
the OSS commit corresponding to the monorepo branch point (found via trailers
on the OSS default branch), then the branch-only commits are replayed.

### `direction: import` (external OSS commits → PR branch)

Replays every first-parent OSS commit after the resume point that we did not
create onto a freshly rebuilt PR branch, re-rooted under `subtree-prefix`. The
caller pushes the branch and opens/updates the sync PR.

The resume point is the recorded `Oss-Commit` trailer that reaches **farthest
along OSS history**, not the one on the newest base-branch commit. Those differ
whenever a later commit records an earlier import (a hand-written re-import, a
repaired trailer), and taking the newest would move the anchor backwards and
re-walk commits already in the subtree.

**The anchor then heals itself from content.** It advances to the newest OSS
commit whose content the subtree already holds. A trailer is a *record* of an
import; the subtree tree is *evidence* of one, and evidence survives what
records do not — a squash, a hand-edited message, a hand-made import that
forgot the trailer. So damaged trailer state repairs itself on every run, with
no marker commit, no repair PR, and no operator action. `healed-count` reports
how far it moved.

Most of that movement is routine. Every OSS commit we exported carries
`Monorepo-Commit` and, by design, never an `Oss-Commit` trailer, so the anchor
trails our own exports until the next import records a trailer past them, and
healing walks over them on the way. `healed-count` is therefore split:
`healed-export-count` is that expected part, and `healed-unrecorded-count`
counts commits carrying **neither** trailer — an import whose provenance record
was lost. Only the latter is annotated, and only it means trailers are being
lost somewhere.

This is safe by construction rather than by heuristic: if the subtree equals
commit `C`'s content, replaying anything up to `C` could only produce a no-op or
a spurious conflict against a later change that is also already present.
Commits after `C` are untouched and imported normally, so healing never swallows
pending work. Without it, the redundant range is re-walked every run — invisible
while each commit still applies as a no-op, then a hard conflict the moment a
later OSS commit touches the same lines as an earlier one.

`seed-oss-commit` remains a floor on the anchor, for the one state healing
cannot resolve: no readable trailer *and* no subtree content matching any OSS
commit, i.e. a sync that has never run or whose subtree was rewritten.

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

**Merge the sync PR with rebase, never squash.** Squashing collapses the
per-commit authorship of external contributions on the base branch, which is the
whole point of the replay. Treat rebase-merge as review policy rather than
wiring auto-merge (which some compliance postures disallow), and use
`direction: health` to detect violations after the fact.

A squash does not corrupt the sync, but only because both directions are
defended against it. GitHub's squash appends `Co-authored-by:` as a *new
paragraph*, which pushes an `Oss-Commit` trailer out of the block git's own
`%(trailers)` parser reads. The trailer stays in the message verbatim while
becoming invisible to that parser, so the anchor freezes and every import
re-walks commits already in the subtree — silently, for as long as each
re-walked patch still applies as a no-op, then as a hard conflict once a later
OSS commit touches the same lines. A squash also collapses several imports onto
one commit, which is what the last defense covers. All four are regression-tested
in `test/squash-tolerance.bats`:

- the `Oss-Commit` lookup scans the **whole commit message**, not just git's
  trailer block, so a squash-orphaned trailer is still read (the value must be a
  bare commit sha at column 0, which keeps most prose from matching, though a
  line of that exact shape quoted in a body does match)
- `Monorepo-Commit` is read from git's trailer **block only**. Export writes that
  trailer itself and pushes straight to OSS, so it is never squash-orphaned and
  the whole-message scan would buy it nothing -- while OSS is public and takes
  outside contributions, so a body line there is contributor-controlled. Scanned,
  a forged `Monorepo-Commit:` line would make an external commit the export
  anchor, putting it before the divergence range so it is never checked, while
  the import loop guard skipped it as ours

> **Known exposure.** Block-only narrows that forgery, it does not end it. The
> same line written as a *real* trailer -- last paragraph, where git's own parser
> reads it -- is still accepted as ours, because nothing at the parser layer
> distinguishes it from a record we wrote. With `align-tree` the forged anchor
> deletes the contributor's content from the mirror and the run reports
> `diverged=false` and succeeds. Closing it needs evidence the parser does not
> have (who pushed the commit), so it belongs with the sync identity rather than
> the trailer reader. Treat `align-tree` on a branch that has taken outside
> contributions as an operation to review, not a routine one.
- the anchor is the farthest-reaching recorded import, so a trailer lost
  outright cannot drag it backwards
- the anchor heals from subtree content, so even a trailer destroyed beyond
  recovery costs nothing but the provenance record
- the export divergence guard reads **every** `Oss-Commit` line instead of the
  newest one per commit, because it asks set membership ("was this sha ever
  absorbed") and not "which record is newest". Last-wins reported all but the
  last sha of a squashed import PR as unabsorbed, on every push, while the import
  direction reported nothing to import — a deadlock no re-run can clear. Content
  cannot settle that one either: an import absorbing a commit *and* the revert
  that superseded it leaves the older commit's content nowhere in the subtree, so
  the trailer record is the only surviving evidence. An abbreviated value is
  resolved to its full sha before the comparison, because a trailer may be
  shortened while the shas it is checked against never are; resolution is
  prefix-checked so it can only ever name the commit the trailer names, which
  matters because `align-tree: true` converges by overwriting the OSS tree
  instead of failing, and a commit wrongly believed absorbed would lose its
  content there

If a maintainer needs to fix up a sync PR, they must add new commits (without an
`Oss-Commit` trailer), never amend the replayed ones; amendments are caught later
by the export convergence assertion.

### `direction: health` (read-only hygiene report)

For hygiene, not outages. Because the import heals its own anchor, nothing this
reports is a broken pipeline waiting to happen — it surfaces the drift a green
run hides. Never commits, pushes, or opens anything, and **never exits non-zero**:
an advisory check must not red the base-branch push job, so a failed fetch or git
call warns, sets `degraded=true`, and returns 0 with whatever it could determine.
Gate on `degraded`, not on the job result. Wire it to `push` on the base branch,
**with `continue-on-error: true`**: the in-script guarantee holds only as long as
no unhandled `set -e`/`set -u` trip slips in, and CLAUDE.md's never-hard-fail
rule for advisory workflows names the flag as the final safety net.

It resolves the anchor through the same `lib.sh` helper the import uses, seed
floor and content healing included, so the report cannot drift from what the
import would actually do — which is precisely the damaged state it exists to
describe.

- **Trailers lagging content.** `stale-anchor` with `recorded-anchor` (what the
  trailers say) against `anchor` (what the import will use). Not an action item
  for the sync, which heals itself, but the affected external commits carry no
  recorded provenance on the base branch, and something is losing trailers. It
  counts `redundant-unrecorded-count` only: `redundant-export-count`, the
  commits we exported ourselves, lags the anchor after every export and is
  never a finding.
- **Squash-merged sync PRs.** `squashed-trailer-count` counts commits carrying an
  `Oss-Commit` value that the whole-message scan finds and git's trailer block
  does not. The comparison is per value, not "is the block empty": a squash of N
  imports leaves only the last of its N trailers in the block, so asking about
  emptiness would score exactly that commit clean.

  Read it as a reason to look, not as proof. A squash produces this shape, and so
  does a real `Oss-Commit:` line quoted at column 0 in a commit body, and the two
  are locally identical. Requiring the value to name a commit in OSS history rules
  out fabricated or unrelated hex and tag objects; it does not rule out a genuine
  sha someone quoted. It also cuts the other way, and a real orphaned record is
  missed when its commit has left OSS history (force-push, recreated branch) or
  when an abbreviated value has since become ambiguous. That direction is the
  chosen one, because the warning tells a human they merged the wrong way.

  Write trailers as full 40-character shas. An abbreviated hand-written value is
  read, and the `^{commit}` lookup disambiguates by type, so a prefix it shares
  with a tree or a blob still resolves. It stops resolving once a second
  *commit-ish* shares the prefix, meaning another commit or an annotated tag that
  points at one, and from then on the export guard can only fall back to the
  content check: absorbed commits whose content was later superseded are the ones
  that then read as unabsorbed, which is exactly the case that deadlocked the
  export in the first place.

  It is still the actionable signal: it is the cause of the lag above, and the lost
  per-commit authorship cannot be recovered after the fact. Enforce rebase-merge.
- **Backlog.** `pending-count` is how many OSS commits genuinely await import.

There is deliberately no repair commit or repair PR, because there is nothing
left for one to fix: the anchor is derived from content on every run, so the
state repairs itself before it can matter. A marker commit would also be a poor
mechanism for it — its diff is empty, so it survives neither a PR nor a
rebase-merge reliably, and pushing one straight to a protected base branch is
what the same posture that rules out auto-merge also rules out.

`seed-oss-commit` covers the single state healing cannot: no readable trailer
*and* no subtree content matching any OSS commit. `health` warns explicitly when
it sees that.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|        INPUT         |  TYPE  | REQUIRED |  DEFAULT  |                                                                                                                                                                                                 DESCRIPTION                                                                                                                                                                                                  |
|----------------------|--------|----------|-----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|      align-tree      | string |  false   | `"false"` |                                                                                       Export only: when the post-replay OSS <br>tree differs from the staging tree, <br>append one snapshot alignment commit instead <br>of failing. Append-only escape hatch; use <br>for migration or after manual reconciliation.                                                                                         |
|        branch        | string |   true   |           |                                                                                                                                                                     Branch to sync (same name on both repos, usually github.ref_name).                                                                                                                                                                       |
|      direction       | string |   true   |           |                                                                                                          export (monorepo subtree -> OSS branch), import (external OSS commits -> PR branch under the subtree), or health <br>(read-only report on anchor staleness and squash-orphaned trailers).                                                                                                           |
|    exclude-paths     | string |  false   |           |                                                           Newline-separated paths (relative to the OSS repo root) that are never <br>mirrored, e.g. producer workflows. Import drops <br>them from replayed diffs; export ignores <br>them in the divergence guard and <br>the convergence assertion. Pass the same <br>list to both directions.                                                             |
|     github-token     | string |   true   |           |                                                Token used to build the OSS <br>remote URL; never logged. Export needs <br>write access to the OSS repo; <br>import and health only read, so <br>give health the least-privileged token that <br>can fetch the OSS branch (github.token suffices for a public OSS repo) <br>rather than a write-capable PAT.                                                  |
|  oss-default-branch  | string |  false   | `"main"`  |                                                                                                                                                           OSS default branch used to anchor <br>newly created release-line branches. Export only.                                                                                                                                                            |
|       oss-repo       | string |   true   |           |                                                                                                                                                                     Downstream OSS repository as owner/repo, e.g. <br>loft-sh/vcluster.                                                                                                                                                                      |
|      pr-branch       | string |  false   |           |                                                                                                                                            Import only: local branch the replayed <br>commits are created on. Defaults to <br>automation/sync-from-oss-<branch>.                                                                                                                                             |
| seed-monorepo-commit | string |  false   |           |                                                                                                                         Monorepo commit to resume from when <br>the OSS branch has no Monorepo-Commit <br>trailer yet (first export run). Must be paired <br>with seed-oss-commit.                                                                                                                           |
|   seed-oss-commit    | string |  false   |           | OSS commit anchor for the first <br>run: paired with seed-monorepo-commit on export. <br>On import it is a floor <br>on the resume point; the health <br>direction applies the same floor so <br>both agree. Rarely needed, since the <br>import heals a damaged anchor from <br>subtree content: only when there is <br>no readable Oss-Commit trailer AND no <br>subtree content matching any OSS commit.  |
|    subtree-prefix    | string |   true   |           |                                                                                                                                 Path of the subtree within this <br>repo, e.g. staging/github.com/loft-sh/vcluster. Requires a full-history <br>checkout (fetch-depth: 0).                                                                                                                                   |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|           OUTPUT           |  TYPE  |                                                                                                                                                                                                                                                                                                                                                                                                   DESCRIPTION                                                                                                                                                                                                                                                                                                                                                                                                   |
|----------------------------|--------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|           anchor           | string |                                                                                                                                                                                                                                                                                                                        Health: the OSS commit the import <br>will resume from, after content healing. <br>Empty only when neither a trailer <br>nor the subtree content identifies one.                                                                                                                                                                                                                                                                                                                         |
|        conflict-sha        | string |                                                                                                                                                                                                                                                                                                                                                         Import: the OSS commit that failed <br>the 3-way apply, when the run <br>failed on a conflict.                                                                                                                                                                                                                                                                                                                                                          |
|         converged          | string |                                                                                                                                                                                                                                                                                                                                                    Health: true when the subtree already <br>holds the OSS branch tip content <br>(ignoring exclude-paths).                                                                                                                                                                                                                                                                                                                                                     |
|          degraded          | string |                                                                                                                                                                                                                                                                                             Health: true when a git or <br>network step failed and some figures <br>in this report are therefore incomplete. <br>The health direction never exits non-zero, <br>so gate on this rather than <br>on the job result.                                                                                                                                                                                                                                                                                              |
|          diverged          | string |                                                                                                                                                                                                                                                                                                                        Export: true when OSS has external <br>commits not yet absorbed and the <br>run failed closed. The documented reaction <br>is to dispatch the import direction.                                                                                                                                                                                                                                                                                                                          |
|       exported-count       | string |                                                                                                                                                                                                                                                                                                                                                        Export: number of commits created on <br>the OSS branch (including an alignment commit, if any).                                                                                                                                                                                                                                                                                                                                                         |
|        has-changes         | string |                                                                                                                                                                                                                                                                                                                                                            Import: true when at least one <br>external commit was replayed onto the <br>PR branch.                                                                                                                                                                                                                                                                                                                                                              |
|        healed-count        | string |                                                                                                                                                                                                                                                                                               Import: number of OSS commits the <br>anchor advanced over because the subtree <br>already held their content. Mostly our <br>own exports; see healed-unrecorded-count for the <br>part that indicates a problem.                                                                                                                                                                                                                                                                                                 |
|    healed-export-count     | string |                                                                                                                                                                                                                                                                            Import: of healed-count, the commits we <br>created ourselves (Monorepo-Commit trailer). They never carry <br>an Oss-Commit trailer, so the anchor <br>trails every export until the next <br>import records one past them. Expected, <br>not a finding.                                                                                                                                                                                                                                                                             |
|  healed-unrecorded-count   | string |                                                                                                                                                                                                                                                                                                                 Import: of healed-count, the commits carrying <br>neither trailer, i.e. imports whose provenance <br>record was lost. Non-zero means trailers <br>are being lost during merge.                                                                                                                                                                                                                                                                                                                  |
|      loose-absorption      | string | Export: true when an external counts <br>as absorbed only via an Oss-Commit <br>line outside the block git's own <br>trailer parser reads AND its content <br>is not in the subtree, i.e. <br>the one combination align-tree refuses to <br>overwrite. An ordinary export still proceeds. <br>A run with align-tree true fails <br>only when there is an alignment <br>to make: the refusal guards the <br>overwrite, so if the trees already <br>agree there is nothing to overwrite <br>and the run succeeds with this <br>still true. Do NOT dispatch the <br>import direction on this alone, it <br>has nothing to replay. When diverged <br>is also true, diverged wins: dispatch <br>the import for the unabsorbed commits. <br>Use the health direction to find <br>squash-orphaned trailers generally.  |
|          oss-tip           | string |                                                                                                                                                                                                                                                                                                                                                                                 Export: the OSS branch tip after <br>the run.                                                                                                                                                                                                                                                                                                                                                                                   |
|       pending-count        | string |                                                                                                                                                                                                                                                                                                                                                                      Health: number of OSS commits genuinely <br>waiting to be imported.                                                                                                                                                                                                                                                                                                                                                                        |
|         pr-branch          | string |                                                                                                                                                                                                                                                                                                                                                                           Import: the local branch holding the <br>replayed commits.                                                                                                                                                                                                                                                                                                                                                                            |
|       push-rejected        | string |                                                                                                                                                                                                                                                                                                                                 Export: true when the push to <br>the OSS branch was rejected by <br>branch protection / a ruleset (the sync identity is not a bypass actor).                                                                                                                                                                                                                                                                                                                                   |
|           pushed           | string |                                                                                                                                                                                                                                                                                                                                                                          Export: true when commits were pushed <br>to the OSS branch.                                                                                                                                                                                                                                                                                                                                                                           |
|      recorded-anchor       | string |                                                                                                                                                                                                                                                                                                                                   Health: the anchor the Oss-Commit trailers <br>actually record, before content healing. Behind <br>`anchor` when trailers have been lost.                                                                                                                                                                                                                                                                                                                                     |
|      redundant-count       | string |                                                                                                                                                                                                                                                                                                                                              Health: number of OSS commits the <br>anchor is behind, i.e. what content <br>healing advances over on every import.                                                                                                                                                                                                                                                                                                                                               |
|   redundant-export-count   | string |                                                                                                                                                                                                                                                                                                                                 Health: of redundant-count, the commits we <br>created ourselves (Monorepo-Commit trailer). Expected after every <br>export, never a finding.                                                                                                                                                                                                                                                                                                                                   |
| redundant-unrecorded-count | string |                                                                                                                                                                                                                                                                                                                                    Health: of redundant-count, the external commits <br>carrying no readable Oss-Commit trailer. This <br>is what stale-anchor reports on.                                                                                                                                                                                                                                                                                                                                      |
|       replayed-count       | string |                                                                                                                                                                                                                                                                                                                                                                                  Import: number of external commits replayed.                                                                                                                                                                                                                                                                                                                                                                                   |
|       skipped-count        | string |                                                                                                                                                                                                                                                                                                                         Import: number of external commits considered <br>but not replayed, because they touch <br>only excluded paths or their content <br>is already in the subtree.                                                                                                                                                                                                                                                                                                                          |
|   squashed-trailer-count   | string |                                                                                                                                                                                                                                                            Health: number of sync commits carrying <br>an Oss-Commit value outside the trailer <br>block git parses, which a squash-merge <br>produces. A reason to look, not <br>proof: a real trailer line quoted <br>in a commit body looks the <br>same. See the README for what <br>it misses.                                                                                                                                                                                                                                                             |
|        stale-anchor        | string |                                                                                                                                                                                                                                                              Health: true when external commits sit <br>in the subtree with no trailer <br>recording them. The import heals this <br>itself; it means those commits carry <br>no recorded provenance on the base <br>branch. Our own exports lag the <br>anchor by design and never set <br>this.                                                                                                                                                                                                                                                               |
|      suggested-anchor      | string |                                                                                                                                                                                                                                                                                                                                                 Health: the content-derived anchor, i.e. what <br>the import heals to. Empty unless <br>stale-anchor is true.                                                                                                                                                                                                                                                                                                                                                   |

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

# Health: on push to the base branch; report only, never fails the job.
- uses: loft-sh/github-actions/.github/actions/oss-commit-sync@oss-commit-sync/v1
  id: health
  continue-on-error: true   # advisory: must never block the push job
  with:
    direction: health
    subtree-prefix: staging/github.com/loft-sh/vcluster
    oss-repo: loft-sh/vcluster
    branch: ${{ github.ref_name }}
    # Read-only direction: the built-in token is enough when the OSS repo is
    # public. Do not hand it the write-capable PAT the other two directions need.
    github-token: ${{ github.token }}
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

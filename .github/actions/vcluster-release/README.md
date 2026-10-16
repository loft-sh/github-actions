# Cut vCluster release

Single entry point for cutting a vCluster release on any supported line. The
version string decides the routing, so nobody has to remember which release
procedure a given version needs.

The GitHub Release is treated as a pipeline **output**, not a trigger. This
action only creates the tag(s) and dispatches each line's own `release.yaml` via
`workflow_dispatch` (`gh workflow run --ref <tag>`, which runs the tagged
commit's version of the workflow). The dispatched builder creates the release at
the end of a green build. Because no builder triggers on `release:created`, a
monorepo-created OSS release cannot re-trigger the OSS builder.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT     |  TYPE  | REQUIRED | DEFAULT  |                                                                                                                                                                                  DESCRIPTION                                                                                                                                                                                   |
|---------------|--------|----------|----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    dry-run    | string |  false   | `"true"` |                                                                            Fail-closed: only an explicit "false" cuts <br>for real. Any other value (the default, a typo, wrong case) <br>runs the read-only routing checks and <br>prints the exact tag + dispatch <br>calls without firing them.                                                                             |
| github-token  | string |   true   |          |                                                                                                                        Token with repo + workflow scope <br>on both loft-sh/vcluster and loft-sh/vcluster-pro (cross-repo tag creation and dispatch).                                                                                                                          |
| source-branch | string |  false   |          | Branch to cut from. Required for <br>-next/-next.internal (the short-lived feature branch). For -rc, leave it <br>empty: the vX.Y release branch is <br>used once it exists and main <br>until then, and an explicit main <br>is REJECTED once vX.Y exists. Must <br>be main for -alpha/-beta and the <br>vX.Y branch for stable; leave empty <br>to take the matrix default.  |
|    version    | string |   true   |          |                                                                                                                                                             Release version to cut, e.g. v0.35.4 <br>or v0.37.2.                                                                                                                                                               |

<!-- AUTO-DOC-INPUT:END -->

## Routing

Two independent decisions: the **prerelease suffix** fixes which branch a version
may be cut from (the `source-branch` input), and the **era** fixes the fan-out.

### Suffix -> source branch (fail-closed)

An unroutable suffix (e.g. `-devpod.alpha`) is rejected, never guessed.

| Suffix | Allowed source branch | Notes |
|--------|-----------------------|-------|
| `-alpha` / `-beta` | `main` only | |
| `-rc` | the `vX.Y` release branch once it exists, `main` until then | checked against the repo on every cut: an explicit `main` is **rejected** once `vX.Y` exists. Leave `source-branch` empty and it picks the right one. Legacy lines are always the `vX.Y` branch |
| stable (`vX.Y.Z`) | the `vX.Y` release branch only | no fallback to `main` |
| `-next` / `-next.internal` | a short-lived feature branch (`source-branch` **required**) | not `main`, not `vX.Y`; **always builds `loft-sh/vcluster-pro` only** |

`-next`/`-next.internal` short-circuit the era routing below.

### Era -> fan-out

Era is decided by a numeric `(major, minor)` compare against the `CUTOVER`
constant (`v0.37`):

| Era | Versions | Fan-out |
|-----|----------|---------|
| legacy | `< v0.37` | `-rc`/stable only, from the `vX.Y` branch in **both** repos; tag OSS, bump the vendored OSS dependency on the pro `vX.Y` branch (auto-merged PR), tag pro, then dispatch `loft-sh/vcluster` **first** and `loft-sh/vcluster-pro`. |
| monorepo | `>= v0.37` | Tag the suffix-resolved branch in `loft-sh/vcluster-pro`, dispatch `loft-sh/vcluster-pro` only. |

`v0.36` is the last legacy line (two-repo dance); `v0.37` is the first
merged/monorepo line. Numeric compare matters: `v0.9` sorts *below* `v0.37`
(legacy), and `v1.0` lands in the monorepo era.

On the legacy path the vendored `github.com/loft-sh/vcluster` dependency on the
pro `vX.Y` branch is bumped to the freshly created OSS tag *during* the cut: the
action dispatches the pro `release-bump-vcluster.yaml` workflow, which opens a
`loft-bot` PR (`chore/<line>/bump-vcluster-<version>`) that `auto-approve-bot-prs`
auto-merges, and the cut blocks on that merge before tagging pro. This replaces
the manual release-prep bump that used to precede a legacy cut, so pro always
builds against the OSS code being co-released.

## Guards

- **Double-cut:** fails only if **every** target repo already has a published
  release for `version`. A release is the pipeline's terminal output (only a
  green build publishes one), so all-released is the one state that proves the
  version actually shipped. Anything short of it is an interrupted cut and is
  resumed instead — see [Re-running a cut](#re-running-a-cut). The tag lookup is
  an exact match (a prerelease like `v0.35.4-rc.1` does not block the final
  `v0.35.4`), and like the branch check every probe distinguishes a real 404 from
  a transient API error rather than silently skipping the guard.
- **Stable ships the last rc:** a stable `vX.Y.Z` is refused unless the
  commit it would tag (or, on a resume, the commit its tag points at) is the
  commit its newest `vX.Y.Z-rc.N` was cut from, in every repo it tags. Commits
  that landed after that rc would otherwise ship untested. The error links the
  commits between the two, and asks for `vX.Y.Z-rc.N+1` only when nothing for
  the version exists yet in any repo. Anywhere else (a tag that exists and is
  never moved, OSS already tagged, a bump already merged) another rc alone
  does not help, so it points at [Re-running a cut](#re-running-a-cut)
  instead. On a legacy line both repos must have
  the same newest rc, since pro vendors OSS, and pro may be one commit past it
  only once that commit is the dependency bump the cut merges itself: its
  `go.mod` requires `vX.Y.Z` and it changes nothing but `go.mod`, `go.sum` and
  `vendor/`, so a fix pushed onto the bump PR does not ride along untested. Both repos are checked before either is
  touched, except for what reaches pro while the cut waits for the bump (a
  commit landing on the branch, or a fix pushed onto the bump PR and squashed
  into it): that is refused when pro is tagged, after OSS. A stable with no rc
  is refused too, and a failed read is refused with a request to re-run.
  Prereleases are not checked.
- **Unprepared line:** fails loudly if a required `vX.Y` branch is absent (no
  silent fallback), distinguishing a real 404 from a transient API error.
- **Undispatchable line:** before anything is tagged, each repo the cut will
  dispatch has its `.github/workflows/release.yaml` read at the commit the
  dispatch would run: the branch head, which is then the commit tagged, or the
  existing tag on a resume. The cut stops if the file has no `workflow_dispatch`
  trigger, has a trigger that could start a second build (`push`, `create`,
  `release`, ...), lacks an input the dispatch passes, or requires one it does
  not, and if GitHub does not list the workflow as `active`. These are the
  `require_dispatchable` rules shared with platform-release, listed in
  [its README](../platform-release/README.md#guards). On a legacy line both
  repos are checked before OSS is tagged, and pro is checked again at the head
  the dependency bump leaves, since anything else that lands during the bump
  wait is tagged with it. A refusal there leaves the OSS tag and the merged bump
  behind, and says so. Monorepo and `-next` dispatches pass `triggered_by`;
  legacy ones pass none. On a resume the file is read at the existing tag, so
  a refusal there says a fix on the branch cannot reach it.
- **Tag on its branch:** a resumed tag whose commit is not on the branch the
  routing chose is not dispatched, in either repo: it would build code that
  branch never had, and name that branch in the banner. The check is
  ancestry, so it cannot tell which of two branches holding the same commit a
  tag was cut from.
- **Source branch:** a line whose `release.yaml` declares a `source_branch`
  input gets the branch the cut tagged, for `notify-release`'s `base_branch`.
  A line without it is dispatched without one. A monorepo rc resumed on its
  `vX.Y` branch is dispatched without it unless `release.yaml` requires it with
  no default: the tag may have been cut from `main` before the line was
  branched, which the cut cannot tell, so the notifier reads the branch from
  git history instead.
- **Branch shape:** `source-branch` is trimmed and validated as a branch name
  before anything reads it, since every consumer puts it in a `gh api` path
  and gh reads `?` as the start of a query string (`main?` would resolve to
  `main` while comparing as a feature branch).
- **Dry-run** still performs the read-only checks, so a bad routing decision
  (missing branch, already-released) is caught before anything is dispatched.
  Dry-run is **fail-closed**: only an explicit `false` cuts for real; any other
  `dry-run` value (a typo, wrong case, empty) stays in dry-run and warns, so a
  misconfigured caller cannot accidentally fire a real cross-repo release.

## Re-running a cut

**Re-running the action with the same version is the recovery procedure.** The
legacy path (tag OSS → bump+merge pro → tag pro → dispatch OSS → dispatch pro) is
not atomic, so a run that dies partway leaves real state behind. Rather than ask
an operator to read the log and hand-unwind it, every step reads that state back
and skips what is already done.

Before touching anything the action resolves a per-repo state:

| State | Meaning | What a re-run does |
| --- | --- | --- |
| `absent` | no tag | tag, then dispatch |
| `tagged` | tag exists, build never dispatched | dispatch only, once a stable tag is found at its last rc (pro: at most the bump past it) |
| `dispatched` | a `release.yaml` run exists **at the tag's current commit** | nothing; prints how to inspect that run |
| `released` | a GitHub Release exists | nothing for this repo |

The pro dependency bump is resumed the same way: an already-merged bump PR is not
re-dispatched and an already-open one is waited on rather than duplicated. Both
shortcuts are confirmed against `go.mod` before they are taken — a merged PR only
proves the bump *once* landed, and "a pro tag exists" says nothing about which
OSS version it vendored. A mismatch is a hard error, never a guess, because
tagging pro against an un-bumped `go.mod` ships a release built on the wrong
OSS code. That read carries the same small retry budget as the merge poll it
follows, since it is the read most exposed to contents-API lag; a file that reads
cleanly and names a different version is an answer, not a blip, and is never
retried.

Two further `release_state` values are conflicts rather than points on that
line, and are refused outright rather than resumed:

- **A tag deleted under a running build.** No tag, but a `release.yaml` run for
  the version has not completed. Re-tagging would point the version at a
  different commit than the build in flight. Keyed on in-flight runs only, so the
  delete-the-tag-and-re-cut path still works once the run has finished. Both the
  "any run" and "still running" questions come from a single query, so they
  cannot disagree about a run that changed state between two requests, and the
  count is taken from each run's own status rather than a `status=` filter, which
  would miss `requested`, `waiting` and `pending`.
- **A tag re-pointed under a running build.** The tag exists, no run matches the
  commit it now points at, but a run for that tag name is still in flight against
  a different one. Dispatching would leave two builds racing to publish one
  version from two commits. (`active` is deliberately counted unscoped so this is
  visible even though the dispatched check is scoped to the commit.)
One further refusal is a comparison ACROSS the two repos rather than a state of
either:

- **OSS behind pro.** The legacy fan-out always tags OSS first, so OSS can never
  legitimately lag pro. If it does, the OSS tag was deleted, and re-creating it
  now would publish an OSS half built from different source than the pro half
  that already shipped.

Two properties this preserves:

- **A tag is never re-pointed.** The tag a previous run created is what its
  already-dispatched build is building; moving it would change what ships under a
  version that is already in flight. The run count is scoped to the commit the
  tag points at (peeling annotated tags), not just the tag name: run records
  outlive tags, so an unscoped count would let a completed run from a previous
  incarnation of a re-cut tag read as "already dispatched" and silently suppress
  the build of the new commit.

- **A build is never dispatched twice.** A run at the tag counts as dispatched in
  *any* conclusion, failed included — a failed build is re-run from its own
  workflow, where the operator can see why it broke. After dispatching, the
  action waits for the run to become queryable, because `gh workflow run` returns
  before that and a cut started in the gap would see the tag with no run.

Two refusals from the rc check are not cleared by pressing the button again:

- **A stable tag that is not at its last rc's commit** (it predates the rc
  check, was made by hand, or an rc was cut after it) is refused on a re-run
  rather than dispatched, since the dispatch would ship it. A re-run never
  moves a tag, so a new rc helps only if it lands exactly on the tagged commit.
  On a legacy line that never happens for pro, whose rc cut merges its own bump
  first. To ship the version from another commit, delete the tag by hand: that
  is fine for a `tagged` loft-sh/vcluster-pro tag, since nothing was built from
  it. On a monorepo line, cut again. On a legacy line the version's bump PR has
  already merged, so the re-cut needs the bump dispatched by hand first, as in
  the next item. Never delete or move a stable tag in loft-sh/vcluster: it is a
  public Go module version that the module proxy may already have recorded, so
  cut the next patch version instead.
- **Pro refused at its tag, after OSS.** A commit that lands on the pro branch
  while a legacy cut waits for the bump is refused when pro is tagged, which
  leaves the OSS tag and the merged bump behind. Cutting `vX.Y.Z-rc.N+1` then
  moves pro's `go.mod` to that rc, and a later stable cut does not re-dispatch
  a bump whose PR already merged, so it stops at the `go.mod` check. Dispatch
  the bump by hand
  (`gh workflow run release-bump-vcluster.yaml --repo loft-sh/vcluster-pro --ref main -f version=<version> -f branch=<line>`),
  wait for it to merge, then cut the stable again. That only works while
  loft-sh/vcluster has not moved past its stable tag; otherwise cut the next
  patch version.

A dispatch GitHub rejects leaves its tag in the `tagged` state and says so, with
gh's reason. Every other partial failure recovers the same way: fix whatever
blocked it (a bump PR that would not merge, a missing branch, an expired token,
a rejected dispatch), then press **Cut release** again with the same version. Use `dry-run: true` first to print
the resume plan without mutating anything.

Genuinely re-cutting an already-shipped version is still refused. To force one,
delete its releases and tags first, or cut a new version.

## Usage

Consumed by a `workflow_dispatch` workflow on the caller's default branch (the
single canonical release button):

```yaml
name: Cut release
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Release version to cut (e.g. v0.35.4 or v0.37.2)"
        type: string
        required: true
      dry_run:
        description: "Print the routing decision and exact calls without firing them"
        type: boolean
        required: true
        default: true

permissions:
  contents: read

jobs:
  vcluster-release:
    if: ${{ github.repository_owner == 'loft-sh' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/vcluster-release@vcluster-release/v2
        with:
          version: ${{ inputs.version }}
          dry-run: ${{ inputs.dry_run }}
          github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

### Runner

The runner needs mikefarah `yq` v4.46.1 or later on `PATH`, which GitHub-hosted
Ubuntu runners include. The action checks this before any API call. `v1`
did not read `release.yaml` and needed no `yq`, which is why this is `v2`.

### Auth

`github-token` must be a Personal Access Token or GitHub App token with `repo` +
`workflow` scope on **both** `loft-sh/vcluster` and `loft-sh/vcluster-pro`
(cross-repo tag creation and dispatch). `secrets.GITHUB_TOKEN` cannot dispatch
into other repos.

It also needs to **read workflow runs** in both repos — `repo` scope covers this
on a classic PAT; a fine-grained PAT needs `Actions: read` granted explicitly.
That read is what tells a re-run whether a tag has already been dispatched, and
it is fail-closed: if the probe cannot answer, the cut aborts naming
`actions:read` rather than risk dispatching a second build of a release that is
already building.

## Testing

```bash
make test-vcluster-release
```

Runs the bats suite in `test/` against `src/vcluster-release.sh` with a configurable
`gh` stub on `PATH` (no real API calls). The preflight parses workflows with the
real `yq`, so mikefarah `yq` v4.46.1+ has to be on `PATH`; the suite stops up
front if it is not. The stub mirrors real `gh` behaviour,
including exiting non-zero on a 404.

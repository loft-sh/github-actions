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

|     INPUT     |  TYPE  | REQUIRED | DEFAULT  |                                                                                                                                 DESCRIPTION                                                                                                                                  |
|---------------|--------|----------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    dry-run    | string |  false   | `"true"` |                           Fail-closed: only an explicit "false" cuts <br>for real. Any other value (the default, a typo, wrong case) <br>runs the read-only routing checks and <br>prints the exact tag + dispatch <br>calls without firing them.                            |
| github-token  | string |   true   |          |                                                                       Token with repo + workflow scope <br>on both loft-sh/vcluster and loft-sh/vcluster-pro (cross-repo tag creation and dispatch).                                                                         |
| source-branch | string |  false   |          | Branch to cut from. Required for <br>-next/-next.internal (the short-lived feature branch). Optional for -rc (main or the vX.Y branch; defaults to main). <br>Must be main for -alpha/-beta and <br>the vX.Y branch for stable; leave <br>empty to take the matrix default.  |
|    version    | string |   true   |          |                                                                                                            Release version to cut, e.g. v0.35.4 <br>or v0.37.2.                                                                                                              |

<!-- AUTO-DOC-INPUT:END -->

## Routing

Two independent decisions: the **prerelease suffix** fixes which branch a version
may be cut from (the `source-branch` input), and the **era** fixes the fan-out.

### Suffix -> source branch (fail-closed)

An unroutable suffix (e.g. `-devpod.alpha`) is rejected, never guessed.

| Suffix | Allowed source branch | Notes |
|--------|-----------------------|-------|
| `-alpha` / `-beta` | `main` only | |
| `-rc` | `main` or the `vX.Y` release branch | empty `source-branch` defaults to `main` |
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
- **Unprepared line:** fails loudly if a required `vX.Y` branch is absent (no
  silent fallback), distinguishing a real 404 from a transient API error.
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
| `tagged` | tag exists, build never dispatched | dispatch only |
| `dispatched` | a `release.yaml` run exists **at the tag's current commit** | nothing; prints how to inspect that run |
| `released` | a GitHub Release exists | nothing for this repo |

The pro dependency bump is resumed the same way: an already-merged bump PR is not
re-dispatched and an already-open one is waited on rather than duplicated. Both
shortcuts are confirmed against `go.mod` before they are taken — a merged PR only
proves the bump *once* landed, and "a pro tag exists" says nothing about which
OSS version it vendored. A mismatch is a hard error, never a guess, because
tagging pro against an un-bumped `go.mod` ships a release built on the wrong
OSS code.

Two further states are refused outright rather than resumed:

- **A tag deleted under a running build.** No tag, but a `release.yaml` run for
  the version has not completed. Re-tagging would point the version at a
  different commit than the build in flight. Keyed on in-flight runs only, so the
  delete-the-tag-and-re-cut path still works once the run has finished. Both the
  "any run" and "still running" questions come from a single query, so they
  cannot disagree about a run that changed state between two requests, and the
  count is taken from each run's own status rather than a `status=` filter, which
  would miss `requested`, `waiting` and `pending`.
- **OSS behind pro.** The legacy fan-out always tags OSS first, so OSS can never
  legitimately lag pro. If it does, the OSS tag was deleted, and re-creating it
  now would publish an OSS half built from different source than the pro half
  that already shipped.

Two properties this preserves:

- **A tag is never re-pointed.** The tag a previous run created is what its
  already-dispatched build is building; moving it would change what ships under a
  version that is already in flight.
The run count is scoped to the commit the tag points at, not just the tag name.
Run records outlive tags, so an unscoped count would let a completed run from a
previous incarnation of a re-cut tag read as "already dispatched" and silently
suppress the build of the new commit.

- **A build is never dispatched twice.** A run at the tag counts as dispatched in
  *any* conclusion, failed included — a failed build is re-run from its own
  workflow, where the operator can see why it broke. After dispatching, the
  action waits for the run to become queryable, because `gh workflow run` returns
  before that and a cut started in the gap would see the tag with no run.

So the recovery for every partial failure is the same: fix whatever blocked it
(a bump PR that would not merge, a missing branch, an expired token), then press
**Cut release** again with the same version. Use `dry-run: true` first to print
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
      - uses: loft-sh/github-actions/.github/actions/vcluster-release@vcluster-release/v1
        with:
          version: ${{ inputs.version }}
          dry-run: ${{ inputs.dry_run }}
          github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

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
`gh` stub on `PATH` (no real API calls). The stub mirrors real `gh` behaviour,
including exiting non-zero on a 404.

# Cut vCluster Platform release

Single entry point for cutting a vCluster Platform (`loft-sh/loft-enterprise`)
release on any supported line. The version string decides the routing, so nobody
has to remember which branch a given version is cut from.

The GitHub Release is treated as a pipeline **output**, not a trigger. This action
only creates the tag and dispatches that line's own `release.yaml` via
`workflow_dispatch` (`gh workflow run --ref <tag>`, which runs the tagged commit's
version of the workflow). The dispatched builder creates the release at the end of
a green build, so nothing triggers on `release:created` and no build can
re-trigger itself.

Platform is always a single repo. The sibling
[`vcluster-release`](../vcluster-release) action carries era classification and a
cross-repo fan-out for the vcluster/vcluster-pro two-repo history; none of that
applies here, so this action keeps only the repo-agnostic core: validate → route →
guard → tag → dispatch.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT     |  TYPE  | REQUIRED | DEFAULT  |                                                                                                                                                                                               DESCRIPTION                                                                                                                                                                                                |
|---------------|--------|----------|----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    dry-run    | string |  false   | `"true"` |                                                                               Fail-closed: only an explicit "false" (in any case) <br>cuts for real. Any other value <br>(the default, a typo, stray whitespace) runs the read-only routing checks <br>and prints the exact tag + <br>dispatch calls without firing them.                                                                                |
| github-token  | string |   true   |          |                                                                                        Token with repo + workflow scope <br>on loft-sh/loft-enterprise (tag creation and workflow dispatch). A PAT, not <br>GITHUB_TOKEN: the tag must still fire <br>the repo tag-push workflows (code-freeze, golangci-lint).                                                                                          |
| source-branch | string |  false   |          | Branch to cut from. Required for <br>-next/-next.internal (the short-lived feature branch). Optional for -rc (empty auto-routes to release-X.Y when that branch exists, else main; an explicit main is refused once release-X.Y exists). <br>Must be main for -alpha/-beta (refused once release-X.Y exists) <br>and the release-X.Y branch for stable; <br>leave empty to take the matrix <br>default.  |
|    version    | string |   true   |          |                                                                                                                                              Release version to cut, e.g. v4.11.3 <br>or v4.12.0-rc.1. The leading v is <br>optional and is added for you.                                                                                                                                               |

<!-- AUTO-DOC-INPUT:END -->

## Routing

The version is read as semver before anything else happens: every numeric
component is `0` or a digit string with no leading zero, and the prerelease body
is checked as semver identifiers. `v4.11.02` is the shape worth naming: it
normalizes unchanged, derives the `release-4.11` line that exists, and probes
clean against the double-cut guard because the shipped tag is `v4.11.2`, so this
gate is the only thing between that typo and a tagged build of a version the Go
module proxy cannot resolve.

The prerelease suffix fixes which branch a version may be cut from (the
`source-branch` input). An unroutable suffix (e.g. `-devpod.alpha`, of which this
repo has historical examples) is rejected, never guessed. The match is anchored at
the start of the prerelease body, so the dashed spelling of the same flavor
(`-devpod-alpha.1`) is rejected too rather than reading as a plain `-alpha`.

| Suffix | Allowed source branch | Notes |
|--------|-----------------------|-------|
| `-alpha` / `-beta` | `main` only | refused once `release-X.Y` exists; cut an rc from the line branch instead |
| `-rc` | `main` or the `release-X.Y` branch | empty `source-branch` auto-routes: `release-X.Y` when that branch exists, else `main` |
| stable (`vX.Y.Z`) | the `release-X.Y` branch only | no fallback to `main` |
| `-next` / `-next.internal` | a short-lived feature branch (`source-branch` **required**) | not `main`, not `release-X.Y` |

Every `-rc` is resolved against the repository before the matrix sees it, whether
or not a `source-branch` was given: the branch state both fills the default **and**
decides whether an explicit `main` is legal.

- `release-X.Y` **exists**: the rc must come from `release-X.Y`. An empty
  `source-branch` takes it; an explicit `main` is **refused**, because `main` now
  carries the next line's development and lacks the fixes backported to the line,
  so an rc cut from it validates the wrong code and nothing downstream would catch
  it.
- `release-X.Y` **absent**: the rc *is* `main`; that is where the line lives
  until it branches. A first minor rc such as `v4.12.0-rc.1` lands here.

This is identical to the `vcluster-release` sibling: the two dispatchers differ in
repository topology, never in which branch an rc may come from. The probe is
read-only, so a dry-run prints the branch a real cut would use, and a transient API
failure aborts rather than reading as "no line branch yet".

Platform release branches are named `release-X.Y` (e.g. `release-4.11`), not
`vX.Y`. The convention is stated once in `LINE_BRANCH_FORMAT` /
`LINE_BRANCH_PATTERN` at the top of `src/platform-release.sh`.

Those constants, and `REPO` / `WORKFLOW` / `DEFAULT_BRANCH` alongside them, are
sourced from `PLATFORM_`-prefixed environment variables. A composite action's
steps inherit the caller's workflow- and job-level `env:`, so a caller that sets
a bare `REPO` would otherwise redirect the entire cut - tag included - at a
different repository, with the dry-run output still reading as consistent. Set
`PLATFORM_REPO`, `PLATFORM_WORKFLOW`, `PLATFORM_DEFAULT_BRANCH`,
`PLATFORM_LINE_BRANCH_FORMAT` or `PLATFORM_LINE_BRANCH_PATTERN` to retarget a
direct invocation.

## Guards

- **Token access:** the repository itself is probed before any branch. GitHub
  answers 404 for a private repo the token cannot see, and every later probe
  reads a 404 as "absent", so without this a missing grant would route the cut
  as if no line branch existed and then report a missing branch. A token that
  can read the repo but not push to it is refused next: it could not create the
  tag, and GitHub hides draft releases from it, so the double-cut guard could
  not see them. GitHub reports no permissions for a GitHub App token, so for
  one the action only warns.
- **Double-cut:** fails if a release for `version` already exists, draft or
  published. Releases are read from the full release list, paged through,
  because the by-tag lookup only answers for published releases. An existing
  tag is not refused: the cut resumes from it (see
  [Partial-failure recovery](#partial-failure-recovery)). The tag is looked up
  as an exact match, so a prerelease like `v4.11.3-rc.1` does not count as
  `v4.11.3`. A failed listing, tag probe or run listing aborts the cut rather
  than silently skipping the guard.
- **Unprepared line:** fails loudly if the target branch is absent (no silent
  fallback), distinguishing a real 404 from a transient API error. A release line
  needs its `release-X.Y` branch (carrying a `workflow_dispatch`-enabled
  `release.yaml` that declares the `triggered_by` input) before it can be cut.
  `gh workflow run` rejects undeclared inputs, so a line whose `release.yaml`
  omits it would fail at the dispatch; the check below refuses it first.
- **Undispatchable line:** before the tag is created, the action resolves the
  target branch head once and reads `.github/workflows/release.yaml` *at that
  sha*, the same commit the tag then lands on, so a push arriving mid-cut
  cannot get tagged without being checked. It fails unless every
  input the dispatch will send, and every input it will not, can be satisfied.
  It refuses a workflow with no `workflow_dispatch` trigger; one that declares
  no `triggered_by` input *under `workflow_dispatch`* while one is being passed
  (a declaration under a `workflow_call` sibling is for that workflow's callers,
  not for `gh workflow run`); and one that declares any other input `required:
  true` with no `default`, which the dispatch cannot fill and the API rejects
  with *Required input not provided*. An empty-string `default` is not counted
  as a default, since an empty value may itself read as not provided. It also
  asks GitHub whether `release.yaml` is a registered, `active` workflow, since a
  disabled one fails the dispatch whatever the file says. The tag is created
  *before* the dispatch and starts the repo's tag-push workflows, so a cut that
  cannot build is stopped before it makes one. The check is read-only, so a
  dry-run catches it too, which the dispatch itself cannot, because dry-run
  never dispatches.

  It also refuses a line that could build off the tag itself: the dispatcher
  premise is that the tag feeds one build and the GitHub Release is that build's
  output, so a half-converted `release.yaml` (`workflow_dispatch` added, the
  old trigger left behind) would start a second build racing the dispatched one
  for the release. Only `workflow_dispatch` and `workflow_call` are allowed
  under `on:`, since neither fires on its own. Any other trigger is refused,
  whatever its filters say: `push` and `create` fire for the tag, `release`
  fires when the dispatched build publishes, and a release workflow has no use
  for the rest. So is a trigger under `on:` that is not a GitHub event name.
  `release.yaml` also refuses to build on anything but a dispatch, so this check
  is the early warning before the tag exists, not the only guard. The probe
  reads the immediate children of `on:` in both spellings, mapping key and
  sequence item, so neither a `workflow_dispatch` input named `push` nor a
  choice option named `push` is mistaken for a trigger. The `workflow_dispatch`
  trigger itself is read the same way, so a deeper key of that name under
  `workflow_call` does not make a line dispatchable.

  The workflow is parsed with mikefarah `yq`, so any legal YAML spelling reads
  the same: block or flow style at every level, the scalar and list forms of
  `on:`, anchors and aliases, CRLF line endings, quoted keys, and a tab after a
  colon. Comments and block-scalar prose are never read as keys, and
  `required: TRUE` counts as required while `required: yes` (a string under
  YAML 1.2) does not. A file `yq` cannot parse is refused with its reason, and
  so is a `workflow_dispatch` input name outside letters, digits, `-` and `_`,
  since that name could not be quoted back into an annotation safely. Two
  shapes `yq` reads but GitHub does not are refused before the tag: a `<<`
  merge key (GitHub supports anchors and aliases, not merge keys) and a key
  repeated in the same mapping.
- **Branch shape:** `source-branch` is validated as a branch name (letters,
  digits, `.`, `_`, `-`, `/`; no leading `-` or `.`, no leading or trailing `/`,
  no path segment starting with `.`, no `..`) before anything reads it. Every consumer puts it in a `gh api` path,
  and gh treats `?` as the start of a query string, so `main?` compared as
  "not main" to the feature-branch guard while resolving to `main` at every
  endpoint, which would have put a `-next` tag on the default branch. A dot
  segment such as `main/.` is the same bypass wherever a hop normalizes the path.
- **Normalization:** the version is canonicalized (leading `v` supplied, stray
  whitespace and a capitalized `V` repaired) *before* anything reads it, so a
  pasted `4.11.3` cannot create a v-less tag that also sails past the double-cut
  probe for `v4.11.3`. `source-branch` is trimmed the same way: the paste that
  drops a space next to a version drops one next to a branch name, and an
  untrimmed branch fails the matrix quoting back a value that looks correct.
- **Dry-run** still performs the read-only checks, so a bad routing decision
  (missing branch, already released) is caught before anything is dispatched.
  Dry-run is **fail-closed**: only an explicit `false` cuts for real; any other
  value (a typo, stray whitespace, empty) stays in dry-run and warns. The match is
  case-insensitive, so `FALSE` typed into the release button does cut for real.

## Partial-failure recovery

The cut is tag-then-dispatch, so an interrupted cut leaves a tag with no build,
or with a build that failed. A successful dispatch prints
`dispatched release.yaml in <repo> at <tag>`, and a resumed one first prints
`resuming at the dispatch without re-tagging`. After dispatching, the cut waits
up to a minute for the new run to show up in the run list, so a cut started
right after it sees the build and refuses instead of dispatching a second one.

The action never deletes a tag. Re-running the cut with the same version picks
up where the last one stopped:

- **Tag exists, no build yet** (the dispatch failed, or the job died after the
  tag was created): the re-run skips the tag and dispatches `release.yaml` at
  the existing tag. The tag is never moved, so the preflight reads
  `release.yaml` at the tagged commit, not at the branch head.
- **Tag exists, earlier builds failed or were cancelled:** the re-run
  dispatches a new build at the same tag.
- **A build is still queued or running at the tag:** the re-run refuses. Wait
  for it to finish, and re-run the cut if it fails. This also holds when the
  tag was deleted under the running build, since re-creating it would start a
  second build from another commit.
- **The tag is not on the target branch** (a stable tag made by hand on
  `main`, or a `-next` tag re-run with another `source-branch`): the re-run
  refuses rather than build the wrong branch.
- **The `-next` feature branch was deleted after tagging:** the re-run warns
  and resumes from the tag. A missing `main` or `release-X.Y` branch is refused.
- **A build at the tag passed but there is no release:** the re-run refuses,
  since another build could publish the version twice. Find out why the build
  did not publish first.
- **A draft release exists for the version:** the re-run refuses. The build
  already got as far as the draft, so promote it with loft-enterprise's own
  `promote-release.yaml` workflow, which is built on the
  [`promote-release`](../promote-release/README.md) action the same way
  [vcluster-pro's](https://github.com/loft-sh/vcluster-pro/blob/main/.github/workflows/promote-release.yaml)
  is. Do not delete the draft.

To restart a build by hand instead, dispatch the builder directly:

```bash
gh workflow run release.yaml --repo loft-sh/loft-enterprise --ref refs/tags/<version>
```

`--ref` is required: without it the default-branch builder runs and may build a
different line. Give it the full `refs/tags/` ref, so a branch with the same
name as the tag cannot be what runs.

## Usage

Consumed by a `workflow_dispatch` workflow on the caller's default branch (the
single canonical release button):

```yaml
name: Cut release
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Version to release, e.g. v4.11.3 | v4.12.0-rc.1 | v4.13.0-next.internal.1"
        type: string
        required: true
      source_branch:
        description: "Branch to cut from. Leave empty in almost every case. Required only for -next/-next.internal."
        type: string
        required: false
        default: ""
      dry_run:
        description: "Preview only: print what would be tagged and dispatched, then stop"
        type: boolean
        required: true
        # Defaults to a preview, matching the action's own fail-closed default:
        # pressing Run without touching the form must never cut for real.
        default: true

permissions:
  contents: read

# Two runs resuming the same tag would both dispatch a build. Queue them instead.
concurrency:
  group: cut-release-${{ inputs.version }}
  cancel-in-progress: false

jobs:
  cut-release:
    if: ${{ github.repository_owner == 'loft-sh' }}
    runs-on: ubuntu-latest
    steps:
      - uses: loft-sh/github-actions/.github/actions/platform-release@platform-release/v1
        with:
          version: ${{ inputs.version }}
          source-branch: ${{ inputs.source_branch }}
          dry-run: ${{ inputs.dry_run }}
          github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

No checkout step is needed: the action only talks to the GitHub API through `gh`.

### Runner

The runner needs mikefarah `yq` v4.46.1 or later on `PATH`. GitHub-hosted Ubuntu
runners include a current release. The action checks this before any API call
and names what it found otherwise, since the python `yq` wrapper shares the
command name but not the query language.

### Auth

`github-token` must be a Personal Access Token or GitHub App token with `repo` +
`workflow` scope on `loft-sh/loft-enterprise`. `secrets.GITHUB_TOKEN` is not a
substitute: a tag created with it does not fire the repo's tag-push workflows
(`code-freeze`, `golangci-lint`), which the current UI-driven flow relies on.

## Testing

```bash
make test-platform-release
```

Runs the bats suite in `test/` against `src/platform-release.sh` with a
configurable `gh` stub on `PATH` (no real API calls). The workflows it feeds the
preflight are parsed by the real `yq`, so mikefarah `yq` v4.46.1+ has to be on
`PATH`; the suite stops up front if it is not. The stub mirrors real `gh`
behaviour, including exiting non-zero on a 404 and prefix-matching the plural
`git/refs/tags/` endpoint, so a regression away from the exact-match singular
endpoint trips the false-double-cut test.

# github-actions

Reusable GitHub Actions

See [Pipeline Conventions](docs/CONVENTIONS.md) for constraints on how actions
are written, tested, and structured.

## Available Actions

### Secret Broker Request Action

Validates a short-lived secret request from an immutable commit, verifies the
authenticated GitHub actor is an active organization member, and durably claims
the request before the caller loads a secret-store credential. It never checks
GitHub team membership or checks out requester-controlled code.

Location: `.github/actions/secret-broker-request`

See [secret-broker-request README](./.github/actions/secret-broker-request/README.md)
for the request schema, two-job integration, permissions, and replay policy.

### Semver Validation Action

Reports on a version string: validity, its parts, its release channel, and how it
orders against another version. Runs [`semstat`](https://github.com/loft-sh/semstat),
installed by the same script as `setup-semstat` below, so the runner needs egress to
the semstat releases and `curl`, `tar`, `sha256sum` and `jq` on it. That is new in
`semver-validation/v4`; the tags before it (`v1`, `v2` and `v3`) point at the
self-contained Node action, which needed neither, and stay available.

**Location:** `.github/actions/semver-validation`

**Usage:**

```yaml
- name: Validate version
  id: semver
  uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v4
  with:
    version: '1.2.3'
    compare_to: '1.2.2'   # optional

- name: Check if valid
  run: echo "Valid: ${{ steps.semver.outputs.is_valid }}"
```

**Inputs:**

- `version` (required): Version string to validate
- `compare_to` (optional): Second version to order `version` against
- `verify-signature` (optional): cosign-verify the semstat release before
  trusting it. Costs a cosign install, so off by default

**Outputs:**

- `is_valid`: Whether the version is valid semver (`true`/`false`)
- `parsed_version`: JSON object with parsed version components
- `error_message`: Error message if validation fails
- `is_stable`, `release_type`: Whether there is a prerelease suffix, and which
  channel it names (`stable`, `alpha`, `beta`, `rc`, `next`, `next-internal`)
- `major`, `minor`, `patch`, `prerelease`, `build`: the parts, flat
- `comparison`, `is_greater`: ordering against `compare_to`, by semver
  precedence rather than `sort -V`

See [semver-validation README](./.github/actions/semver-validation/README.md) for detailed documentation.

### Setup semstat Action

Installs [`semstat`](https://github.com/loft-sh/semstat) from a pinned release,
checksum-verifies it, and puts it on `PATH`. This is where the installer and the
release pin live: the actions that answer semver questions run it rather than
carrying a copy of either. Actions in this repository run its script out of the
same checkout; workflows and other repositories use the action below.

**Location:** `.github/actions/setup-semstat`

**Usage:**

```yaml
- name: Install semstat
  id: semstat
  uses: loft-sh/github-actions/.github/actions/setup-semstat@<sha> # setup-semstat/v1
  with:
    verify-signature: true   # optional, off by default

- name: Order two versions from a shell function
  run: |
    newer_than() { semstat gt "$1" "$2"; }
    newer_than v4.9.0 v4.9.0-rc.2
```

**Inputs:**

- `version` (optional): Release of `loft-sh/semstat` to install. Empty takes the
  Renovate-tracked pin in `src/install-semstat.sh`
- `verify-signature` (optional): cosign-verify `checksums.txt` against semstat's
  release workflow at that exact tag. Costs a cosign install, so off by default

**Outputs:**

- `path`: Absolute path to the verified binary. The directory holding it is on
  `PATH` for later steps as well, since consumers call semstat from inside shell
  functions and loops where a step output is not in scope

See [setup-semstat README](./.github/actions/setup-semstat/README.md) for detailed documentation.

### Linear Release Sync Action

Syncs Linear issues to the "Released" state when a GitHub release is published. Finds PRs between releases, extracts Linear issue IDs, and moves matching issues from "Ready for Release" to "Released".

**Location:** `.github/actions/linear-release-sync`

**Usage:**

```yaml
- name: Sync Linear issues
  uses: loft-sh/github-actions/.github/actions/linear-release-sync@linear-release-sync/v1
  with:
    release-tag: ${{ needs.publish.outputs.release_version }}
    repo-name: my-repo
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
    linear-token: ${{ secrets.LINEAR_TOKEN }}
```

See [linear-release-sync README](./.github/actions/linear-release-sync/README.md) for detailed documentation.

### Link Backport PRs Action

Links modern and legacy backport PRs to the matching Linear sub-issue (`[X.Y] Copy of ...`) by adding `Fixes <id>` to every matching PR body, so the per-release-line issue closes when the backport merges. Wired into the [`backport.yaml`](./docs/workflows/backport.md) reusable workflow and runs after both producer paths settle; advisory and skipped when no `linear-token` is configured.

**Location:** `.github/actions/link-backport-prs`

**Usage:**

```yaml
- uses: loft-sh/github-actions/.github/actions/link-backport-prs@link-backport-prs/v1
  with:
    source-pr: ${{ github.event.pull_request.number }}
    repo-owner: ${{ github.repository_owner }}
    repo-name: ${{ github.event.repository.name }}
    additional-repos: loft-sh/vcluster,loft-sh/vcluster-pro
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
    linear-token: ${{ secrets.LINEAR_API_TOKEN }}
```

See [link-backport-prs README](./.github/actions/link-backport-prs/README.md) for detailed documentation.

### Run Ginkgo Tests

Runs Ginkgo tests with directory or label-based filtering and generates a
JSON failure summary. Runtime-agnostic — callers handle their own cluster and
image setup (vind, Kind, bare Docker).

**Location:** `.github/actions/run-ginkgo`

**Usage:**

```yaml
- name: Run E2E tests
  id: e2e
  uses: loft-sh/github-actions/.github/actions/run-ginkgo@run-ginkgo/v1
  with:
    ginkgo-label: "my-suite && !non-default"
    test-image: ghcr.io/loft-sh/vcluster:dev
    # test-image-flag: "--platform-image"  # default: --vcluster-image
    # additional-ginkgo-flags: "-v --skip-package=linters"
    # additional-args: "--use-license-server=false"

- name: Notify on failure
  if: failure()
  uses: loft-sh/github-actions/.github/actions/ci-test-notify@ci-test-notify/v1
  with:
    test-name: "E2E Tests"
    status: failure
    details: ${{ steps.e2e.outputs.failure-summary }}
    webhook-url: ${{ secrets.SLACK_WEBHOOK }}
```

**Inputs:**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `test-image` | yes | | Image passed to the test binary |
| `test-image-flag` | no | `--vcluster-image` | CLI flag name for the image |
| `timeout` | no | `60m` | Ginkgo test timeout |
| `procs` | no | `8` | Parallel Ginkgo processes |
| `test-dir` | no | | Directory-based test selection (mutually exclusive with `ginkgo-label`) |
| `ginkgo-label` | no | | Label-based test selection (mutually exclusive with `test-dir`) |
| `append-pr-label` | no | `true` | Append `\|\| pr` to the label filter |
| `e2e-dir` | no | `e2e-next` | Root test directory |
| `additional-args` | no | | Extra args for the test binary (after `--`) |
| `additional-ginkgo-flags` | no | | Extra ginkgo CLI flags |

**Outputs:**

- `failure-summary`: Markdown-formatted test results summary

### Sticky PR Comment

Upserts a sticky comment on a pull request, identified by a stable HTML
marker. If a comment with the marker already exists it is updated in place,
otherwise a new comment is created. Domain-agnostic — the caller composes
the body. Useful for surfacing the last real run of a CI signal that the
caller skips on some events (e.g. e2e tests skipped when PR description is
unchanged), so reviewers always see the most recent meaningful result.

**Location:** `.github/actions/sticky-pr-comment`

**Usage:**

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Run tests
        id: tests
        run: ./run-tests.sh

      - name: Upsert sticky status comment
        if: always() && github.event_name == 'pull_request'
        uses: loft-sh/github-actions/.github/actions/sticky-pr-comment@sticky-pr-comment/v1
        with:
          marker: '<!-- e2e-status -->'
          body: |
            ### E2E Tests
            Status: ${{ steps.tests.outcome }}
            Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

**Inputs:**

- `marker` (required): HTML comment uniquely identifying this comment stream (form `<!-- some-id -->`)
- `body` (required): markdown body (the marker is auto-prepended when missing)
- `pr-number` (optional, default: current PR)
- `repo` (optional, default: current repo)
- `github-token` (required): token with `pull-requests: write`

**Outputs:**

- `comment-id`: numeric ID of the upserted comment
- `action-taken`: `created` or `updated`

The action is intended to be invoked from inside the job whose status it
reports — when that job is skipped via `if:`, the upsert never runs and the
previous comment stays in place, which is the desired "preserve last real
result" behavior. See the action README for full details.

### Parse label filter

Parses the ` ```label-filter``` ` fenced block from a PR description, resolves
the Ginkgo label filter, and decides whether a `pull_request` `edited` event
can be skipped. E2E workflows trigger on `edited` so editing the label-filter
re-targets suites without a new commit, but that also re-runs the suite when a
bot (e.g. `cursor[bot]`) edits the PR description. The action returns
`skip-edited=true` when the label-filter block is unchanged across an edit, so
the caller can skip the suite. Side-effect free.

**Location:** `.github/actions/parse-label-filter`

**Usage:**

```yaml
jobs:
  parse-label-filter:
    runs-on: ubuntu-22.04
    outputs:
      label-filter: ${{ steps.parse.outputs.label-filter }}
      skip-edited: ${{ steps.parse.outputs.skip-edited }}
    steps:
      - name: Parse label filter
        id: parse
        uses: loft-sh/github-actions/.github/actions/parse-label-filter@parse-label-filter/v1
        with:
          pr-body: ${{ github.event.pull_request.body }}
          previous-pr-body: ${{ github.event.changes.body.from }}
          event-name: ${{ github.event_name }}
          event-action: ${{ github.event.action }}
          label-filter-input: ${{ inputs.ginkgo-label }}

  e2e-tests:
    needs: [parse-label-filter]
    if: needs.parse-label-filter.outputs.skip-edited != 'true'
    runs-on: large-8_32
    steps:
      - run: echo "filter ${{ needs.parse-label-filter.outputs.label-filter }}"
```

**Inputs:**

- `pr-body` (optional): current PR description (`${{ github.event.pull_request.body }}`)
- `previous-pr-body` (optional): PR description before an edit (`${{ github.event.changes.body.from }}`)
- `event-name` (optional): `${{ github.event_name }}`
- `event-action` (optional): `${{ github.event.action }}`
- `label-filter-input` (optional): manual-dispatch fallback (`${{ inputs.ginkgo-label }}`)

**Outputs:**

- `label-filter`: resolved filter (parsed block, else dispatch input, else `pr`)
- `skip-edited`: `true` only for an `edited` event whose label-filter is unchanged

Pair with a concurrency group that splits edited from code events
(`...-${{ github.event.action == 'edited' && 'edited' || 'code' }}`) so a bot
edit cannot cancel a still-running code run and then skip. See the action
README for full details.

### Comment-triggered check

Turns a PR comment such as `/test-e2e snapshots` into a check-run on the pull
request's head commit, and completes it when the caller's work finishes. It
runs no tests: it decides whether a command should run, resolves the pull
request identity that an `issue_comment` event does not carry, and owns the
check-run lifecycle.

Two modes. `start` parses the comment, authorizes the commenter from
`author_association`, resolves the head SHA and base ref, and opens the
check-run, in two API calls. `finish` resolves the outcome with a fail-closed
matrix, completes the check-run, then confirms it is still displayed and
republishes it if not — three calls, or four when it republishes. So five for a
normal lifecycle and six when a check-run has to be republished.

**Location:** `.github/actions/comment-triggered-check`

**Usage:**

```yaml
permissions:
  checks: write
  pull-requests: read
  contents: read

jobs:
  prepare:
    if: github.event.issue.pull_request && startsWith(github.event.comment.body, '/test-e2e')
    runs-on: ubuntu-22.04
    outputs:
      should-run: ${{ steps.cmd.outputs.should-run }}
      filter: ${{ steps.cmd.outputs.filter }}
      head-sha: ${{ steps.cmd.outputs.head-sha }}
      base-ref: ${{ steps.cmd.outputs.base-ref }}
      key: ${{ steps.cmd.outputs.concurrency-key }}
      check-run-id: ${{ steps.cmd.outputs.check-run-id }}
    steps:
      - id: cmd
        uses: loft-sh/github-actions/.github/actions/comment-triggered-check@comment-triggered-check/v1
        with:
          mode: start
          comment-body: ${{ github.event.comment.body }}
          comment-author: ${{ github.event.comment.user.login }}
          author-association: ${{ github.event.comment.author_association }}
          pr-number: ${{ github.event.issue.number }}
          run-id: ${{ github.run_id }}
          server-url: ${{ github.server_url }}

  # Deduplication is GitHub's: a second identical command supersedes this run,
  # and the always() finish job still closes the superseded check.
  suite:
    needs: [prepare]
    if: needs.prepare.outputs.should-run == 'true'
    runs-on: large-8_32
    concurrency:
      group: comment-triggered-check-suite-${{ github.event.issue.number }}-${{ needs.prepare.outputs.key }}
      cancel-in-progress: true
    outputs:
      check-conclusion: ${{ steps.run.outputs.check-conclusion }}
    steps:
      # Replace this placeholder with the suite. It must test head-sha and emit
      # one of success, failure, neutral, cancelled, or timed_out.
      - id: run
        run: echo "check-conclusion=success" >> "$GITHUB_OUTPUT"

  finish:
    needs: [prepare, suite]
    if: always() && needs.prepare.outputs.check-run-id != ''
    runs-on: ubuntu-22.04
    steps:
      - uses: loft-sh/github-actions/.github/actions/comment-triggered-check@comment-triggered-check/v1
        with:
          mode: finish
          check-run-id: ${{ needs.prepare.outputs.check-run-id }}
          report-conclusion: ${{ needs.suite.outputs.check-conclusion }}
          suite-result: ${{ needs.suite.result }}
          details-url: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

**Key outputs:** `matched`, `should-run`, `reason`, `head-sha`, `base-ref`,
`concurrency-key`, `check-name`, `check-run-id`, `conclusion`.

Two things that are easy to get wrong and are handled here. An `issue_comment`
run's `GITHUB_SHA` is the default branch, so a check-run must be created against
the resolved head SHA or it never appears on the PR, and neither the head SHA
nor the base ref can be inferred from the event. Fork PRs are rejected as a
security boundary, because this trigger is privileged. See the action README.

### Repository Dispatch

Sends a `repository_dispatch` event to a target repository so any source repo
can trigger any event type with one mechanical step. Domain-agnostic — the
caller chooses the event-type and payload schema, the receiver routes on
them. Foundation for cross-repo triggers (release fan-out, downstream test
runs).

**Location:** `.github/actions/repository-dispatch`

**Usage:**

```yaml
- name: Notify vcluster-docs of release
  uses: loft-sh/github-actions/.github/actions/repository-dispatch@repository-dispatch/v1
  with:
    target-repo: loft-sh/vcluster-docs
    event-type: vcluster-released
    payload: |
      {
        "version": "${{ github.ref_name }}",
        "sha": "${{ github.sha }}"
      }
  env:
    GH_TOKEN: ${{ secrets.CROSS_REPO_DISPATCH_TOKEN }}
```

**Inputs:**

- `target-repo` (required): `<owner>/<repo>` of the receiver
- `event-type` (required): matched against the receiver's `on.repository_dispatch.types`
- `payload` (optional, default `{}`): JSON object sent as `client_payload`

`GH_TOKEN` is read from the step's environment, not from inputs — it must be
a PAT or GitHub App token with `repo` scope on the target. See the action
README for full details.

### Release Branch Code Freeze

Applies or lifts a temporary code freeze on a release branch by managing a
repository ruleset with the "Restrict updates" rule. During the freeze only a
bypass team can merge into the branch; unfreeze disables the ruleset so the
branch returns to its standing rules. One reusable ruleset per repo is
re-pointed at the branch being released, so only that branch is frozen.

**Location:** `.github/actions/release-branch-freeze`

**Usage:**

```yaml
- name: Freeze the release branch
  uses: loft-sh/github-actions/.github/actions/release-branch-freeze@release-branch-freeze/v1
  with:
    operation: freeze
    repository: ${{ github.repository }}
    branch: ${{ github.event.ref }}
    bypass-team-id: "16898535" # loft-sh/Eng-Tech-Leads
  env:
    GH_TOKEN: ${{ secrets.CODE_FREEZE_TOKEN }}
```

**Inputs:**

- `operation` (required): `freeze` or `unfreeze`
- `repository` (required): `<owner>/<repo>` to manage
- `branch` (freeze only): release branch to freeze, e.g. `v0.36`
- `bypass-team-id` (freeze only): numeric team id allowed to merge during the freeze
- `enforcement` (optional, default `active`): `active`, `evaluate` (dry run), or `disabled`

`GH_TOKEN` is read from the step's environment, not from inputs. It must be a
PAT or GitHub App token with Administration read and write on the target repo.
See the action README for full details.

### Cut vCluster release

Single entry point for cutting a vCluster release on any supported line. The
version string decides the routing (legacy `< v0.36` fans out to both
`loft-sh/vcluster` and `loft-sh/vcluster-pro`; monorepo `>= v0.36` dispatches
`loft-sh/vcluster-pro` only). Creates the tag(s) and dispatches each line's own
`release.yaml`; the GitHub Release is a pipeline output, not a trigger.

**Location:** `.github/actions/vcluster-release`

**Usage:**

```yaml
- uses: loft-sh/github-actions/.github/actions/vcluster-release@vcluster-release/v1
  with:
    version: ${{ inputs.version }}
    dry-run: ${{ inputs.dry_run }}
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

**Inputs:**

- `version` (required): release version, e.g. `v0.35.4` or `v0.36.2`
- `dry-run` (optional, default `true`): run read-only routing checks and print the tag + dispatch calls without firing them
- `github-token` (required): PAT/App token with `repo` + `workflow` scope on both `loft-sh/vcluster` and `loft-sh/vcluster-pro`

See the [action README](./.github/actions/vcluster-release/README.md) for routing and guard details.

### Subtree Mirror Action

Mirrors a monorepo subtree to a downstream OSS repository. Fast-forward-only for release lines; marker-guarded force push for the mirror branch so contributions merged directly on the OSS repo are never silently destroyed. On divergence it fails closed, sets `diverged=true`, and leaves the OSS branch untouched.

**Location:** `.github/actions/subtree-mirror`

**Usage:**

```yaml
- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  with:
    fetch-depth: 0
    persist-credentials: false

- id: mirror
  uses: loft-sh/github-actions/.github/actions/subtree-mirror@subtree-mirror/v1
  with:
    subtree-prefix: staging/github.com/loft-sh/vcluster
    oss-repo: loft-sh/vcluster
    branch: ${{ github.ref_name }}
    force: ${{ github.ref_name == 'main' }}
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

**Inputs:**

- `subtree-prefix` (required): Subtree path within this repo. Requires `fetch-depth: 0`.
- `oss-repo` (required): Downstream repo as `<owner>/<repo>`.
- `branch` (required): Target branch on the OSS repo (usually `github.ref_name`).
- `github-token` (required): Token with write access to the OSS repo.
- `force` (optional, default `false`): `true` = marker-guarded force push; `false` = fast-forward-only.
- `marker-ref` (optional, default `refs/sync/mirror-head`): Ref tracking the last mirrored SHA. Force mode only.
- `allow-divergent-force` (optional, default `false`): Bypass the divergence guard. Force mode only.

**Outputs:**

- `diverged`: `true` when the OSS branch had unmirrored commits and the force push was refused.
- `pushed`: `true` when a push was performed.
- `split-sha`: The subtree split SHA that was (or would have been) pushed.

See [subtree-mirror README](./.github/actions/subtree-mirror/README.md) for detailed documentation.

### OSS Commit Sync Action

Successor to Subtree Mirror. Bidirectional per-commit sync between a monorepo subtree and a downstream OSS repository: replays each commit's diff (3-way, re-rooted) preserving author, date, and message, and links the two histories with `Monorepo-Commit` / `Oss-Commit` trailers as the only sync state. Incremental (O(new commits), no `git subtree split`), append-only (never force-pushes), fails closed on divergence and conflicts.

**Location:** `.github/actions/oss-commit-sync`

**Usage:**

```yaml
- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  with:
    fetch-depth: 0
    persist-credentials: false

# monorepo -> OSS (on push touching the subtree)
- id: sync
  uses: loft-sh/github-actions/.github/actions/oss-commit-sync@oss-commit-sync/v1
  with:
    direction: export
    subtree-prefix: staging/github.com/loft-sh/vcluster
    oss-repo: loft-sh/vcluster
    branch: ${{ github.ref_name }}
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}

# OSS -> monorepo PR branch (on cron / divergence dispatch)
- id: import
  uses: loft-sh/github-actions/.github/actions/oss-commit-sync@oss-commit-sync/v1
  with:
    direction: import
    subtree-prefix: staging/github.com/loft-sh/vcluster
    oss-repo: loft-sh/vcluster
    branch: main
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

**Key inputs:** `direction` (`export`/`import`), `subtree-prefix`, `oss-repo`, `branch`, `github-token`; `align-tree` (export escape hatch: append one snapshot alignment commit on tree drift), `exclude-paths` (import: OSS-only paths dropped during replay), `seed-monorepo-commit`/`seed-oss-commit` (first run only).

**Key outputs:** export: `pushed`, `diverged`, `exported-count`, `oss-tip`; import: `has-changes`, `replayed-count`, `skipped-count`, `conflict-sha`, `pr-branch`.

See [oss-commit-sync README](./.github/actions/oss-commit-sync/README.md) for the full contract, safety mechanisms, and migration steps.

### Wait For Release Action

Blocks until a GitHub Release for a version exists in another repository, for pipelines where one repo's build uploads assets into a release that another repo's build creates. Presence polling alone cannot tell "the producer is still building" apart from "the producer already failed", so the optional `workflow` input makes the wait status-aware: a producer run that has already concluded unsuccessfully fails the wait immediately, with that run's URL and the recovery order, instead of spending the whole timeout on a precondition that can never be met.

**Location:** `.github/actions/wait-for-release`

**Usage:**

```yaml
- uses: loft-sh/github-actions/.github/actions/wait-for-release@wait-for-release/v1
  with:
    repo: loft-sh/vcluster
    version: ${{ steps.get_version.outputs.release_version }}
    workflow: release.yaml
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

**Inputs:**

- `repo` (required): Repository publishing the release, as `<owner>/<repo>`.
- `version` (required): Release tag to wait for, e.g. `v0.36.1-rc.2`.
- `workflow` (optional): Workflow file in `repo` that produces the release. Enables fail-fast on an already-failed producer run. Omit for a plain presence poll.
- `max-attempts` (optional, default `120`): Polls before giving up. Wall-clock ceiling is `max-attempts x interval-seconds`.
- `interval-seconds` (optional, default `15`): Seconds between polls.
- `max-api-failures` (optional, default `5`): Consecutive API failures tolerated, so one blip cannot fail a release.
- `github-token` (required): Token with `contents:read` on `repo`, plus `actions:read` when `workflow` is set.

**Outputs:**

- `waited-seconds`: Approximate seconds spent waiting before the release appeared.
- `release-url`: URL of the release that was found.

See [wait-for-release README](./.github/actions/wait-for-release/README.md) for the full behaviour table.

### Commitlint

Lints commit messages and pull request titles against the calling repository's own [commitlint](https://commitlint.js.org/) config. The config always comes from the caller: this action decides what gets linted and when to skip, the repository decides what the rules are. Note the trust model in the action README - the config is read from the checkout, so on a fork pull request it is a contributor-facing aid rather than an enforcement boundary. On a squash-merged repository the pull request title is what lands on the default branch, so linting the title is the check that actually protects history; per-commit range linting is the secondary one. When the calling repository's `package.json` mentions `commitlint`, its dependencies are installed and the local binary is used, so CI runs exactly what contributors run locally; otherwise the CLI alone is fetched with `npx`.

**Location:** `.github/actions/commitlint`

**Usage:**

```yaml
- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  with:
    fetch-depth: 0
    persist-credentials: false

- uses: loft-sh/github-actions/.github/actions/commitlint@commitlint/v1
  with:
    pr-title: ${{ github.event.pull_request.title }}
    from: ${{ github.event.pull_request.base.sha }}
    to: ${{ github.event.pull_request.head.sha }}
    branch: ${{ github.event.pull_request.head.ref }}
    head-repository: ${{ github.event.pull_request.head.repo.full_name }}
    skip-branches: 'sync-from-oss/*'
```

**Inputs:**

- `pr-title` (optional): Message to lint on its own. Empty skips the check.
- `from` (optional): Range start for per-commit linting. Empty skips the check. Needs `fetch-depth: 0`.
- `to` (optional, default `HEAD`): Range end for per-commit linting.
- `branch` (optional): Branch name matched against `skip-branches`.
- `head-repository` (optional): Repository the branch lives on. Pass this whenever `skip-branches` is set: on a fork PR the branch name is author-chosen, so the skip list is ignored when this differs from `github.repository`.
- `skip-branches` (optional): Comma-separated globs; a match exits successfully without linting. For branches whose commits cannot be rewritten, such as the rebase-merged `sync-from-oss` branches.
- `config-path` (optional): Config path. Empty uses commitlint's own discovery.
- `working-directory` (optional, default `.`): Directory to run in.
- `commitlint-version` (optional): Version used when the caller pins none. The default lives in `action.yml`, which is the copy Renovate keeps current.
- `fail-on-warnings` (optional, default `false`): Treat warnings as failures.

**Outputs:**

- `skipped`: `true` when `skip-branches` matched and nothing was linted.
- `pr-title-result`: `pass`, `fail`, `skipped`, or `error` when commitlint could not run.
- `commits-result`: `pass`, `fail`, `skipped`, or `error` when commitlint could not run.

Reading an output requires `continue-on-error: true` on the step, since a failing step skips the rest of the job. See the action README for the full pattern.

See [commitlint README](./.github/actions/commitlint/README.md) for detailed documentation.

## Available Reusable Workflows

### Validate Renovate Config

Validates Renovate configuration files when they change in a pull request.

**Location:** `.github/workflows/validate-renovate.yaml`

**Usage:**

```yaml
name: Validate Renovate Config

on:
  pull_request:

jobs:
  validate-renovate:
    uses: loft-sh/github-actions/.github/workflows/validate-renovate.yaml@main
```

Detected config files: `renovate.json`, `renovate.json5`, `.renovaterc`, `.renovaterc.json`, `.github/renovate.json`, `.github/renovate.json5`.

### Auto-approve bot PRs

Approves (and optionally merges) PRs from trusted bot accounts
whose title or branch matches a known safe pattern (`chore:` / `fix(deps):` /
`backport/` / `renovate/` / `update-platform-version-`). Hardened to **never
block caller CI**: `continue-on-error: true` on the job, every shell step
catches its own errors and exits 0, self-approval is pre-empted before calling
the external approve action.

With `auto-merge: true` the merge is performed **directly**, with GitHub's
auto-merge queue only as a fallback. Pass the optional `merge-token` secret when
the approving identity has no merge path on the base branch. When omitted, the
workflow keeps using `gh-access-token` for both operations. See the action's
[README](.github/actions/auto-approve-bot-prs/README.md#merging).

**Location:** `.github/workflows/auto-approve-bot-prs.yaml`

**Usage:**

```yaml
name: Auto-approve bot PRs

on:
  pull_request:
    types: [opened, synchronize]

jobs:
  auto-approve:
    permissions:
      pull-requests: write
      contents: read
      checks: read      # required — CI poll reads /commits/:sha/check-runs
      statuses: read    # required — CI poll reads /commits/:sha/status
    uses: loft-sh/github-actions/.github/workflows/auto-approve-bot-prs.yaml@main
    with:
      trusted-authors: 'renovate[bot],loft-bot,github-actions[bot],dependabot[bot]'
      auto-merge: false
    secrets:
      gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
      # Optional: a separate identity with a merge path on the base branch.
      merge-token: ${{ secrets.MERGE_TOKEN }}
```

`gh-access-token` must be a PAT whose identity differs from PR authors you want
to auto-approve (GitHub forbids self-review). When identity matches, the job
skips gracefully instead of failing.

**Unless you pass the `ci-read-token` secret, `checks: read` and `statuses: read`
are not optional, and the called workflow cannot supply them for you** — GitHub only lets a reusable
workflow downgrade the caller's `GITHUB_TOKEN` permissions, never elevate them,
and anything you omit defaults to `none`. Omit them and the CI poll 403s, the
action default-denies, and the PR is never approved while both the check and the
job still report success. See
[`auto-approve-bot-prs/README.md`](.github/actions/auto-approve-bot-prs/README.md)
for why the approving PAT cannot be used for these reads (fine-grained PATs have
no Checks permission at all).

**End-to-end coverage:** scenario-level e2e lives in
[vClusterLabs-Experiments/auto-approve-e2e](https://github.com/vClusterLabs-Experiments/auto-approve-e2e).
Runs weekly and on demand. Creates real PRs exercising every decision-table
branch (chore/fix(deps) titles, backport/renovate/update-platform-version
branches, ineligible titles) and asserts the never-hard-fail invariant.

### AI step

Small reusable building block: run an AI call with a caller-supplied prompt
and input, bind the output to a JSON Schema, expose the schema-conforming
JSON as a step output. Downstream steps parse with `fromJSON(...)` and
branch on typed fields.

Structured output is the contract. Schema-conforming output is exposed on
`result` with `conclusion=success`; any failure degrades to
`conclusion=failed` with an empty `result` and exit code 0 — the caller
knows what a failed result means for their pipeline. Setting the `agent`
input switches the action to a session against a deployed managed agent
from `loft-sh/ai-agents` (Anthropic-only, minutes not seconds, needs a
workspace session key).

**Location:** `.github/actions/ai-step`

**Usage:**

```yaml
- uses: actions/checkout@v4
  with:
    repository: loft-sh/github-actions
    ref: ai-step/v1
    sparse-checkout: .github/actions/ai-step

- id: classify
  uses: ./.github/actions/ai-step
  with:
    provider: anthropic
    effort: low
    prompt: 'Classify this diff. Return JSON matching the schema.'
    input: ${{ steps.diff.outputs.text }}
    output-schema: |
      {
        "type": "object",
        "required": ["severity", "areas"],
        "properties": {
          "severity": { "type": "string", "enum": ["low","medium","high"] },
          "areas":    { "type": "array",  "items": { "type": "string" } }
        }
      }
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}

- if: fromJSON(steps.classify.outputs.result).severity == 'high'
  run: echo "needs human review"
```

See [ai-step README](./.github/actions/ai-step/README.md) for inputs,
outputs, and provider asymmetries.

### Actionlint

Lints GitHub Actions workflow files using actionlint with reviewdog integration.

**Location:** `.github/workflows/actionlint.yaml`

**Usage:**

```yaml
name: Actionlint

on:
  pull_request:

jobs:
  actionlint:
    uses: loft-sh/github-actions/.github/workflows/actionlint.yaml@main
```

**Inputs:**

- `reporter` (optional, default: `github-pr-review`): reviewdog reporter type

### Publish Helm Chart

Packages a Helm chart and pushes one tarball per version to ChartMuseum.
Handles release pushes (single semver, optional `--app-version`) and head
pushes (multiple `0.0.0-*` versions) under the same contract. Optionally
re-pushes the repo's highest semver afterwards so it stays first in the
upload-ordered ChartMuseum index.

**Location:** `.github/actions/publish-helm-chart`

**Usage (release push):**

```yaml
jobs:
  publish-chart:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          ref: v1.2.3
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/publish-helm-chart@publish-helm-chart/v2
        with:
          chart-name: vcluster
          app-version: 1.2.3
          chart-versions: '["1.2.3"]'
          chart-museum-user: ${{ secrets.CHART_MUSEUM_USER }}
          chart-museum-password: ${{ secrets.CHART_MUSEUM_PASSWORD }}
```

**Usage (head/dev push):**

```yaml
jobs:
  push-head-chart:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/publish-helm-chart@publish-helm-chart/v2
        with:
          chart-name: vcluster-head
          chart-description: "vCluster HEAD - Development builds from main branch"
          app-version: head-${{ github.sha }}
          chart-versions: '["0.0.0-latest","0.0.0-${{ github.sha }}"]'
          chart-museum-user: ${{ secrets.CHART_MUSEUM_USER }}
          chart-museum-password: ${{ secrets.CHART_MUSEUM_PASSWORD }}
```

**Inputs:**

- `chart-name` (required): chart name written to `Chart.yaml` and used in the tarball filename
- `chart-description` (optional): value written to `.description` in `Chart.yaml`
- `app-version` (optional): passed as `--app-version` to `helm package`
- `chart-versions` (required): JSON array of versions, e.g. `'["1.2.3"]'`
- `chart-directory` (optional, default: `chart`): chart source path
- `values-edits` (optional): newline-separated `jsonpath=value` pairs applied via yq to `<chart-directory>/values.yaml`
- `helm-version` (optional, default: `v4.1.4`)
- `republish-latest` (optional, default: `"false"`): re-push highest semver to keep it first in the ChartMuseum index
- `chart-museum-url` (optional, default: `https://charts.loft.sh/`)
- `chart-museum-user` (required)
- `chart-museum-password` (required)

**Note:** The `ref` input was removed — the caller owns `actions/checkout` and checks out the desired ref directly.

### Promote Release

Retags moving Docker tags onto an already-published version with
digest-preserving `crane tag`, and can promote the caller's own GitHub Release,
a paired public release, and a Homebrew formula. It is stable-version-only and
guards every moving pointer against backport regressions.

**Location:** `.github/actions/promote-release`

See [promote-release README](./.github/actions/promote-release/README.md) for
the supported `workflow_dispatch` wiring, inputs, token scopes, and full safety
contract. Keeping the copy-paste example there avoids two documentation sources
drifting apart.

### Govulncheck

Runs [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck)
against a Go module and, on scheduled runs, posts a Slack notification
(via `ci-test-notify`) when vulnerabilities are found. The scan always
marks the job failed on vulnerabilities — notification is the side
channel, not the gate.

**Location:** `.github/actions/govulncheck`

**Usage (public repo, weekly schedule):**

```yaml
name: govulncheck

on:
  schedule:
    - cron: "0 12 * * 1" # Mon 12:00 UTC
  workflow_dispatch:
  pull_request:
    paths:
      - ".github/workflows/govulncheck.yaml"

jobs:
  scan:
    runs-on: ubuntu-latest
    if: github.repository_owner == 'loft-sh'
    permissions:
      contents: read
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/govulncheck@govulncheck/v1
        with:
          slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

**Usage (private repo that depends on `github.com/loft-sh/*`):**

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    if: github.repository_owner == 'loft-sh'
    permissions:
      contents: read
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/govulncheck@govulncheck/v1
        with:
          scan-paths: "./... ./cmd/..."
          private-repo: "true"
          gh-access-token: ${{ secrets.GH_ACCESS_TOKEN }}
          slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

**Inputs:**

- `scan-paths` (optional, default: `./...`): space-separated Go package patterns
- `test-flag` (optional, default: `true`): pass `-test` to govulncheck
- `go-version-file` (optional, default: `go.mod`): passed to `actions/setup-go`
- `private-repo` (optional, default: `false`): enable git url rewrite + `GOPRIVATE`
- `goprivate` (optional, default: `github.com/loft-sh/*`)
- `govulncheck-version` (optional, default: `latest`)
- `test-name` (optional, default: `govulncheck`): Slack header
- `notify` (optional, default: `true`): send Slack on vulnerabilities; fires on `schedule` events only
- `gh-access-token` (required when `private-repo: true`)
- `slack-webhook-url` (required when `notify: true` and the run is on `schedule`)

**Notes:**

- The caller checks out its own source and controls `runs-on`/`timeout-minutes`/fork guarding at the job level.
- A composite action cannot declare `timeout-minutes` on its steps; set `timeout-minutes` on the caller job (default ~10m is reasonable for most modules).

### CVE Scan

Scans a container image for CVEs with a swappable scanner backend (Snyk ships
first) and reports via Slack, a short markdown summary, and the scanner's own
SARIF for the Security tab. Three
outcomes, handled differently on purpose: a **scanner error** (registry
failure, timeout) never fails the job; **findings** only fail it when
`block-on-findings: true` is explicitly turned on, so the default is
advisory-only; and a **config error** (bad threshold,
or a scanner that can't be set up) always fails it, regardless of
`block-on-findings`.

**Location:** `.github/actions/cve-scan`

**Usage (release event, scanning the just-published prerelease image):**

```yaml
name: cve-scan (release)

on:
  release:
    types: [created]

jobs:
  scan:
    if: github.event.release.prerelease == true
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions:
      contents: read
      packages: read
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          ref: ${{ github.event.release.tag_name }}
          persist-credentials: false

      # Release tags are `v0.36.1-rc.4`; the published image tag is
      # `0.36.1-rc.4`. Passing the release tag straight through yields a tag
      # that doesn't resolve, which reports as a scanner error and leaves the
      # job green having scanned nothing.
      - id: image-tag
        shell: bash
        env:
          RELEASE_TAG: ${{ github.event.release.tag_name }}
        run: echo "tag=${RELEASE_TAG#v}" >> "$GITHUB_OUTPUT"

      - uses: loft-sh/github-actions/.github/actions/cve-scan@cve-scan/v1
        with:
          image-ref: ghcr.io/loft-sh/vcluster-pro:${{ steps.image-tag.outputs.tag }}
          enabled: ${{ vars.CVE_SCAN_ENABLED }}
          block-on-findings: ${{ vars.CVE_SCAN_BLOCK_ON_FINDINGS }}
          scanner-token: ${{ secrets.SNYK_TOKEN }}
          registry-username: ${{ github.actor }}
          registry-password: ${{ secrets.GITHUB_TOKEN }}
          slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

**Inputs:**

- `image-ref` (required): full registry reference to scan
- `dockerfile-path` (optional, default: empty): passed to the scanner as `--file` for base-image remediation advice; it does not change which vulnerabilities are found
- `scanner` (optional, default: `snyk`): selects `src/scanners/<scanner>.sh`
- `scanner-token` (required by the snyk adapter): named generically so a tool swap never renames this input
- `scanner-version` (optional, renovate-pinned): scanner CLI version to install and checksum-verify
- `severity-threshold` (optional, default: `high`)
- `enabled` (optional, default: `true`): kill switch; resolves toward scanning on an unrecognised value
- `block-on-findings` (optional, default: `false`): advisory vs. blocking posture
- `registry` (optional, default: `ghcr.io`) / `registry-username` / `registry-password`: the action pulls the image with the caller's own credentials rather than relying on the scanner vendor's registry integration
- `notify` / `slack-webhook-url` (optional, default: `true` / —): gated by `notify-events` as well, so both have to admit a run before it posts
- `notify-events` (optional, default: `schedule,release`): comma-separated allowlist of `github.event_name` values permitted to notify, so a `workflow_dispatch` or PR run stays silent unless it opts in. A `workflow_call` callee sees the caller's event name

**Outputs:**

- `has-vulnerabilities`, `critical-count`, `high-count`, `medium-count`, `low-count`
- `scanner-error`: `true` if the scan couldn't complete — distinct both from finding CVEs and from a setup error, which fails the job
- `report-path`, `sarif-path` (written by the scanner), `summary` (Slack-ready text)

See [cve-scan README](./.github/actions/cve-scan/README.md) for suppressing findings via `.snyk`, the scanner-adapter exit-code contract, how to resolve the image tag per repo, and the SARIF upload example.

### Checkov

Runs [Checkov](https://www.checkov.io/) against infrastructure as code, open
source packages, container images, and CI/CD configurations. This is a local
copy of [`bridgecrewio/checkov-action`](https://github.com/bridgecrewio/checkov-action)
(Apache-2.0) vendored verbatim — same inputs, outputs, and behavior. We host it
here because the upstream action publishes too many git tags for Renovate to
enumerate releases; the vendored copy pins the checkov Docker image
(`docker://ghcr.io/bridgecrewio/checkov:<tag>`) directly, which Renovate's
built-in `github-actions` manager keeps up to date via the `runs.image`
reference.

**Location:** `.github/actions/checkov` (see `LICENSE` and `NOTICE` there)

**Usage:**

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
      - uses: loft-sh/github-actions/.github/actions/checkov@checkov/v1
        with:
          directory: .
          framework: terraform
          soft_fail: "true"
          output_format: cli
```

**Inputs/outputs:** identical to the upstream action — see its
[input table](https://github.com/bridgecrewio/checkov-action#inputs). Common
inputs: `directory` (default `.`), `file`, `framework`, `skip_check`, `check`,
`soft_fail`, `quiet`, `compact`, `config_file`, `output_format` (default
`sarif`), `output_file_path`. The single output is `results`.

**Notes:**

- This is a Docker action; it does not need a `checkout`-installed toolchain,
  but the caller must still check out the code it wants scanned.
- To bump checkov, let Renovate update the image tag in `action.yml` — do not
  re-point callers at the upstream action.

## Testing

Run all action tests locally:

```bash
make test
```

Run tests for a specific action:

```bash
make test-semver-validation
make test-linear-pr-commenter
make test-linear-release-sync
```

Run linters (actionlint + zizmor):

```bash
make lint
```

See all available targets:

```bash
make help
```

### CI integration

Each testable action has a dedicated workflow that runs its tests on PRs when
the action's files change:

- `test-semver-validation.yaml` - triggers on `.github/actions/semver-validation/**`
- `test-setup-semstat.yaml` - triggers on `.github/actions/setup-semstat/**`
- `test-linear-pr-commenter.yaml` - triggers on `.github/actions/linear-pr-commenter/**`
- `test-link-backport-prs.yaml` - triggers on `.github/actions/link-backport-prs/**`
- `test-linear-release-sync.yaml` - triggers on `.github/actions/linear-release-sync/**`
- `test-sticky-pr-comment.yaml` - triggers on `.github/actions/sticky-pr-comment/**`
- `test-comment-triggered-check.yaml` - triggers on `.github/actions/comment-triggered-check/**`
- `release-linear-release-sync.yaml` - builds and publishes the binary on tag push or `workflow_dispatch`

Each reusable workflow (`workflow_call`) also has a smoke/integration test
workflow that triggers on PRs when the workflow file changes:

- `test-validate-renovate.yaml` - calls `validate-renovate.yaml` with local ref.
  **Note:** When triggered by workflow YAML changes alone, the inner `paths-filter`
  won't match any renovate config files so `npx renovate-config-validator` never runs.
  The validator only exercises its full path when `renovate.json` is also changed.
- `test-detect-changes.yaml` - calls `detect-changes.yaml` and asserts outputs (true/false)
- `test-actionlint-workflow.yaml` - calls `actionlint.yaml` with `github-pr-check` reporter (PR-only).
  **Note:** `actionlint.yaml` skips fork PRs silently; the verify job emits a warning when this happens.
- `test-backport.yaml` - calls `backport.yaml` and asserts the result is `skipped`
- `test-clean-github-cache.yaml` - calls `clean-github-cache.yaml` (PR-only, since the
  underlying workflow needs `github.event.pull_request.number`)
- `test-cleanup-backport-branches.yaml` - calls `cleanup-backport-branches.yaml` with `dry-run: true`
- `test-conflict-check.yaml` - calls `conflict-check.yaml` and asserts success or skipped
- `test-claude-code-review.yaml` - calls `claude-code-review.yaml` to validate workflow is callable
- `test-claude.yaml` - calls `claude.yaml` and asserts `skipped` (no `@claude` comment event)
- `test-notify-release.yaml` - calls `notify-release.yaml` with dummy inputs to validate the contract

Post-merge, `dispatch-integration-tests.yaml` triggers full E2E tests in
[vClusterLabs-Experiments/github-actions-test](https://github.com/vClusterLabs-Experiments/github-actions-test).

### Writing tests for new actions

1. Composite actions with shell logic - put the logic in `src/*.sh` and add a
   `test/` directory with bats suites. See `semver-validation/test/report.bats`
   for the pattern: stub the binaries the script calls, run it with `INPUT_*`
   env vars and a temp `GITHUB_OUTPUT` file, then assert on the outputs.

2. Go actions - add `*_test.go` files next to the source. See
   `linear-pr-commenter/src/main_test.go`. Use standard `go test`.

3. Composite actions (YAML-only like `release-notification`) - these
   delegate to third-party actions and have no local business logic to unit
   test. Validate their YAML structure through actionlint instead.

4. Add a Makefile target for the new action following the existing pattern.

5. Add a CI workflow at `.github/workflows/test-<action-name>.yaml` with a
   `paths` filter scoped to the action's directory.

6. Add `AUTO-DOC-INPUT`/`AUTO-DOC-OUTPUT` markers to the action's `README.md`
   and run `make generate-docs` (see [Documentation](#documentation)).

## Documentation

Action and reusable workflow documentation is auto-generated from
`action.yml` / workflow YAML using [tj-actions/auto-doc](https://github.com/tj-actions/auto-doc).
Each action README and each workflow doc in `docs/workflows/` contains
`AUTO-DOC-INPUT`, `AUTO-DOC-OUTPUT`, and `AUTO-DOC-SECRETS` marker comments
that are filled in by the tool.

Regenerate all docs locally:

```bash
make generate-docs
```

Verify docs are up to date (CI runs this on every PR):

```bash
make check-docs
```

Install the auto-doc binary only (downloaded to `.bin/`):

```bash
make install-auto-doc
```

### Workflow docs

Reusable workflow documentation lives in `docs/workflows/<workflow-name>.md`.
Each file maps 1:1 to a `workflow_call` workflow in `.github/workflows/`.

### Adding docs for a new action or workflow

1. **Action** -- add `## Inputs` and `## Outputs` sections with marker comments
   to the action's `README.md`:

   ```markdown
   ## Inputs

   <!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->
   <!-- AUTO-DOC-INPUT:END -->

   ## Outputs

   <!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->
   <!-- AUTO-DOC-OUTPUT:END -->
   ```

2. **Reusable workflow** -- create `docs/workflows/<name>.md` with `## Inputs`,
   `## Outputs` (if applicable), and `## Secrets` marker sections.

3. Run `make generate-docs` and commit the result.

## Versioning Actions

### Release-notification Action

The existing release-notification action uses a repository-wide tag:

```bash
git tag -f v1
git push origin v1 --force
```

Referenced as:

```yaml
uses: loft-sh/github-actions/release-notification@v1
```

### New Actions

For all new actions, we use action-specific tags for independent versioning:

```bash
# For the ci-notify-nightly-tests action
git tag -f ci-notify-nightly-tests/v1
git push origin ci-notify-nightly-tests/v1 --force

# For the semver-validation action
git tag -f semver-validation/v4
git push origin semver-validation/v4 --force

# For other actions, follow the same pattern
git tag -f action-name/v1
git push origin action-name/v1 --force
```

These tags float, and callers pin them by name, so a force-push reaches every one
of those callers on their next run with no change on their side. That is the point
when shipping a fix, and the wrong tool when the new code asks something of the
caller that the old code did not: a runner requirement, network egress, a token, a
permission, a change to the job's environment. Cut the next major instead and leave
the existing tags where they are, so callers meet the new requirement when they
choose to move.

`semver-validation` is the worked example. `v1`, `v2` and `v3` are the self-contained
Node implementation; the composite over `semstat` needs egress to the semstat
releases, needs `curl`/`tar`/`sha256sum`/`jq` on the runner, verifies its download
by default and so needs Sigstore egress too, and drops the `semstat_version` input,
so it went out as `v4` rather than over any of them. It leaves the job's `PATH`
alone, which would otherwise have been a reason on its own. Before force-pushing a
tag, check who pins it:

```bash
gh search code 'loft-sh/github-actions/.github/actions/<action-name>@ org:loft-sh'
```

### Referencing Actions in Workflows

```yaml
# Reference actions using their specific tag
uses: loft-sh/github-actions/.github/actions/ci-notify-nightly-tests@ci-notify-nightly-tests/v1
uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v4
```

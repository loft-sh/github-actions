# Commitlint

Lints commit messages and pull request titles against the calling repository's
own [commitlint](https://commitlint.js.org/) config.

Two independent checks, both optional:

- **`pr-title`** lints a single message. On a squash-merged repository the pull
  request title is what actually lands on the default branch, so this is the
  check that protects history.
- **`from`/`to`** lints every commit in a range. Merge commits and reverts are
  skipped by commitlint's own default ignores. The caller must check out with
  `fetch-depth: 0`, since a shallow clone cannot walk the range.

Both run to completion even when the first one fails, so a contributor sees
every problem in one run rather than one per push.

The config always comes from the calling repository, never from this action.
This action decides *what* gets linted and *when to skip*; the repository
decides what the rules are.

## Trust model

Read this before treating a green check as a guarantee.

The config, and any `node_modules/.bin/commitlint`, are read from the checkout.
On a pull request from a fork that checkout is the merge result, whose contents
the pull request author controls. A fork can therefore weaken
`commitlint.config.js`, or commit an executable `node_modules/.bin/commitlint`
that exits 0, and this action will report `pass`.

So the check is a **contributor-facing aid on fork pull requests, not an
enforcement boundary**. What it does enforce is the non-fork case: branches in
the repository itself, which is where release automation, backports and the
`sync-from-oss` branches live, and where a squash-merged title is what lands on
the default branch.

`skip-branches` is guarded against the fork case (see below) because a branch
*name* is the one thing a fork controls that this action would otherwise read
before looking at any repository content. That guard closes a bypass that
needed no commit at all; it does not make the fork case trustworthy.

If you need enforcement against forks, lint the squash-merge title in a
separate job that resolves the config from the base ref rather than the
checkout, or enforce at merge time.

## Commitlint version

When the calling repository's `package.json` mentions `commitlint`, its
dependencies are installed and the local binary is used, so CI runs exactly
what contributors run locally. That covers `@commitlint/*`,
`@your-scope/commitlint-config` and `commitlint-config-*` alike. If the install
fails the action warns and falls back rather than failing the check on an npm
problem.

Otherwise `commitlint-version` is fetched on the fly with `npx`. **That path
brings the CLI only.** A config that `extends` a shared package such as
`@commitlint/config-conventional` must declare it in a `package.json` whose
text contains `commitlint`, or nothing is installed and commitlint cannot
resolve the config. Without `fail-on-warnings` that exits 1, which is
indistinguishable from a lint failure and is reported as `fail`; with
`fail-on-warnings: true` it is distinguishable and reported as `error`. A
self-contained config with no `extends` works fine on the `npx` path.

The known gap is a package that the config depends on but whose name contains
no `commitlint` at all: a `parserPreset` such as
`conventional-changelog-conventionalcommits`. Declaring any `@commitlint/`
dependency alongside it is enough to trigger the install.

Installs run with `--ignore-scripts`, since on a fork pull request the manifest
being installed comes from the fork and commitlint needs no lifecycle scripts.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT        |  TYPE  | REQUIRED |  DEFAULT   |                                                                                                                                                               DESCRIPTION                                                                                                                                                               |
|--------------------|--------|----------|------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|       branch       | string |  false   |            |                                                                                                                  Branch name matched against skip-branches. Pass <br>the github.event.pull_request.head.ref context.                                                                                                                    |
| commitlint-version | string |  false   | `"19.8.1"` |                                                                                                                      Version of @commitlint/cli used when the <br>calling repository does not pin one <br>itself.                                                                                                                       |
|    config-path     | string |  false   |            |                                                                                                   Path to the commitlint config. Empty <br>lets commitlint discover it, which finds <br>commitlint.config.js at the repository root.                                                                                                    |
|  fail-on-warnings  | string |  false   | `"false"`  |                                                                                                                                                 Treat commitlint warnings as failures.                                                                                                                                                  |
|        from        | string |  false   |            |                                                                                     Range start for per-commit linting. Pass <br>the github.event.pull_request.base.sha context. Requires to as <br>well; leave both empty to skip <br>the check.                                                                                       |
|  head-repository   | string |  false   |            | Repository the branch lives on. Pass <br>the github.event.pull_request.head.repo.full_name context. When this is <br>set and differs from github.repository the <br>pull request comes from a fork, <br>where the branch name is chosen <br>by its author, and skip-branches is <br>ignored. Always pass this alongside skip-branches.  |
|      pr-title      | string |  false   |            |                                                                                            Message to lint on its own. <br>Pass the pull request title, the <br>github.event.pull_request.title context. Leave empty to skip <br>the check.                                                                                             |
|   skip-branches    | string |  false   |            |                Comma-separated glob patterns. When branch matches <br>one of them the action exits <br>successfully without linting anything. Intended for <br>branches carrying commits that cannot be <br>rewritten, such as the rebase-merged sync-from-oss <br>branches that replay community authorship verbatim.                  |
|         to         | string |  false   |  `"HEAD"`  |                                                                                                                                          Range end for per-commit linting, normally <br>HEAD.                                                                                                                                           |
| working-directory  | string |  false   |   `"."`    |                                                                                                                                      Directory to run in. Must contain <br>the commitlint config.                                                                                                                                       |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT      |  TYPE  |                                                  DESCRIPTION                                                   |
|-----------------|--------|----------------------------------------------------------------------------------------------------------------|
| commits-result  | string | pass, fail, skipped, or error when <br>commitlint itself could not run and <br>the commits were never judged.  |
| pr-title-result | string | pass, fail, skipped, or error when <br>commitlint itself could not run and <br>the message was never judged.   |
|     skipped     | string |                          true when skip-branches matched and nothing <br>was linted.                           |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

Lint the pull request title and every commit on the branch:

```yaml
name: Commitlint

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

permissions:
  contents: read

jobs:
  commitlint:
    runs-on: ubuntu-latest
    steps:
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

### Linting the title only

For a repository that squash-merges and does not care about the shape of
intermediate commits:

```yaml
      - uses: loft-sh/github-actions/.github/actions/commitlint@commitlint/v1
        with:
          pr-title: ${{ github.event.pull_request.title }}
```

`fetch-depth: 0` is unnecessary in this mode.

### Exempting branches

`skip-branches` takes comma-separated globs matched against `branch`. A match
exits the action successfully without linting anything.

This exists for branches carrying commits that cannot be rewritten. The
`sync-from-oss` branches are the motivating case: they are rebase-merged to
preserve external authorship, so community subjects land verbatim and no
amount of CI can change them.

```yaml
        with:
          branch: ${{ github.event.pull_request.head.ref }}
          head-repository: ${{ github.event.pull_request.head.repo.full_name }}
          skip-branches: 'sync-from-oss/*, backport/*'
```

**Always pass `head-repository` alongside `skip-branches`.** On a fork pull
request the branch name is chosen by the pull request author, so without it
anyone could opt out of linting by naming their branch after an exempt
pattern. When `head-repository` differs from `github.repository` the skip list
is ignored and a warning is logged.

Patterns are globs rather than regexes, so `sync-from-oss/*` reads the way an
author expects and does not match `feat/sync-from-oss-docs`.

### Warnings

Warnings are reported but do not fail the check. A repository rolling out a
rule gradually can keep it at warning level in its own config; set
`fail-on-warnings: true` to promote every warning to a failure.

## Reading the outputs

The outputs exist to tell `error` (commitlint could not run) apart from `fail`
(commitlint ran and rejected a message). That distinction only matters on a run
where the action fails, and a failing step skips every later step in the job,
so consuming an output requires `continue-on-error: true` on the action step
plus an explicit final gate:

```yaml
      - id: commitlint
        continue-on-error: true
        uses: loft-sh/github-actions/.github/actions/commitlint@commitlint/v1
        with:
          pr-title: ${{ github.event.pull_request.title }}

      - if: steps.commitlint.outputs.pr-title-result == 'error'
        run: echo "::warning::Commit linting could not run. This is a CI problem, not your commit message."

      # Anything that is not a clean pass fails the job, an exempt branch
      # aside. `error` covers a transient outage AND permanent caller
      # misconfiguration - a working-directory that no longer exists, for
      # instance - so gating only on `fail` would turn a broken setup into a
      # permanently green check that lints nothing.
      - if: >-
          steps.commitlint.outputs.skipped != 'true' &&
          steps.commitlint.outputs.pr-title-result != 'pass'
        run: exit 1
```

Read the exemption off the `skipped` output, not off a result being `skipped`.
A result is also `skipped` when the input wired into that check resolved to an
empty string, meaning that check linted nothing, so a gate accepting `skipped`
results is green on exactly the mis-wiring you want to hear about. The
`skipped` output is `true` only when `skip-branches` matched.

Gate each result separately, and only the ones you requested: a check the
caller never asked for reports `skipped` too, so a gate on `commits-result` in
the title-only example above would fail every run.

Without `continue-on-error`, the action still fails the job on a bad message,
which is the normal wiring and needs none of the above.

One caveat if you wrap this action inside a composite action of your own rather
than calling it from a workflow: `continue-on-error` on a *composite* step must
be a literal boolean, because an expression is evaluated in the composite's own
context, resolves empty, and halts the run with `Unexpected value ''`
([actions/runner#2418][coe], still open). Workflow job steps, as in the example
above, take expressions normally.

[coe]: https://github.com/actions/runner/issues/2418

## Permissions

`contents: read` is enough. The action makes no API calls and needs no token.

Run it on `pull_request`, not `pull_request_target`. On a fork pull request the
action checks out and installs from the fork's own manifest; `pull_request`
grants no secrets and a read-only token, which is what makes that safe.
`pull_request_target` runs with the base repository's secrets and would turn
the same install into a credential-exfiltration path.

## Testing

```bash
make test-commitlint
```

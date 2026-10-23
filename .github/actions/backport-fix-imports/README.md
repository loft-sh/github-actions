# Backport fix imports

Repairs Go module paths on a backport branch when the target release line is
on an older module major than the source. The case it was built for:
`loft-enterprise` moved `main` to `github.com/loft-sh/loft/v5` and
`github.com/loft-sh/api/v5`, while every `release-4.x` branch stays on v4. A
cherry-pick from `main` then carries v5 imports into a v4 branch, and conflicts
wherever both sides edited the same import block.

## What it does

Run inside a full-history checkout of the repository, on a backport branch that
already exists on the remote:

1. Reads the root `go.mod` on the source and target branches and maps the
   modules the repository owns: the `module` line, and `replace` directives
   that point into the repository (`=> ./...`). Third-party modules are never
   rewritten, so a dependency major bump on `main` is left alone.
2. Moves files the backport added under a source-only local directory (for
   example `staging/src/github.com/loft-sh/api/v5/...`) into the target's
   directory. A file whose target path already exists is not moved and is
   left for review.
3. Resolves conflict hunks made only of import lines inside an import block.
   The backported side wins, rewritten to the target paths. An import only the
   target side had stays while the code uses it, ignoring comments and strings.
   The package name is read from the source, never guessed from the path
   (`github.com/json-iterator/go` is package `jsoniter`): the standard library
   by its last element, the repository's own modules from their directory, and
   everything else from `vendor/`. The hunk is left for review instead when
   the name cannot be read, when both sides import the same path differently
   (another name, another comment such as `//nolint`), or when a comment line
   only the target side has would be lost.
4. Rewrites the mapped paths in the `.go` files the backport changed, only at
   the start of a string literal and on a path boundary.
5. Runs `gofmt` on files whose import blocks it resolved, then commits as
   `github-actions[bot]` and pushes one commit:
   `fix(backport): use <target-branch> module paths`.

Conflict hunks in real code, undecidable import hunks and blocked moves are
left as they are, with a warning per file, and the `reason` says how many files
are left for review. A second run finds nothing to
rewrite and reports `unchanged`, so re-runs are safe.

The action never fails the job: every failure path ends with `conclusion=failed`,
a one-line `reason` and exit 0, and nothing is pushed.

## AI pass

Only with `anthropic-api-key` set, and only when `.go` files the backport
changed still have conflicts after the fix. Non-Go conflicts are never sent.

1. Each conflicted Go file goes, whole, to [`ai-step`](../ai-step/README.md) in
   one call. The model answers per conflict block: replacement code, or "not
   sure".
2. A file is changed only when every block in it has an answer with no conflict
   markers.
3. Each touched package must pass `gofmt` and `go vet`, and have no other
   conflicted file. Packages that pass are committed as
   `fix(backport): resolve conflicts with ai`. The rest are reverted.
4. Before that commit is pushed, the backport PR gets the
   `backport-ai-resolved` label, so auto-approve can keep it for a person. If
   the PR cannot be labeled, the AI commit is not pushed.

`gofmt` and `go vet` run without the push token in their environment.

So a wrong or partial answer never reaches the branch. It stays a conflict for a
person, as without the AI pass. The pass is skipped when there are more than 20
conflict blocks or the input would exceed 300 KB.

## PR comment

When there is something to tell the assignee, the action upserts one sticky
comment on the backport PR: the fix commit, the AI commit to review closely,
and each file left for them with the reason. No comment when nothing was
changed and nothing is left.

## Usage

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    fetch-depth: 0
    persist-credentials: false

- id: fix
  uses: loft-sh/github-actions/.github/actions/backport-fix-imports@backport-fix-imports/v1
  with:
    target-branch: release-4.12
    backport-branch: backport/release-4.12/pr-8606
    github-token: ${{ secrets.GH_ACCESS_TOKEN }}

- env:
    CONCLUSION: ${{ steps.fix.outputs.conclusion }}
    REASON: ${{ steps.fix.outputs.reason }}
  run: echo "$CONCLUSION: $REASON"
```

The runner needs `python3` and `git`; `gofmt` is optional and only formats the
import blocks it resolved (it ships on GitHub-hosted Ubuntu runners). The AI
pass also needs `go`, which GitHub-hosted runners have. Pushing
with a PAT, rather than `GITHUB_TOKEN`, is what makes the fix commit trigger
the backport PR's CI.

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|       INPUT       |  TYPE  | REQUIRED | DEFAULT  |                                                                                  DESCRIPTION                                                                                  |
|-------------------|--------|----------|----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| anthropic-api-key | string |  false   |          |    Anthropic API key. Set, it turns <br>on the AI pass for Go <br>conflicts left after the fix; empty, <br>the AI pass never runs. Needs <br>go and gofmt on the runner.      |
|  backport-branch  | string |   true   |          |                               Head branch of the backport PR, <br>e.g. backport/release-4.12/pr-8606. Checked out, fixed and <br>pushed back.                                 |
|   github-token    | string |   true   |          | Token with contents write on the <br>repository, used to fetch and push <br>the backport branch. Supplied to git <br>through the environment, never argv or <br>.git/config.  |
|       push        | string |  false   | `"true"` |                                                         false commits the fix locally without <br>pushing (dry run).                                                          |
|   source-branch   | string |  false   | `"main"` |                                        Branch the original change merged into. <br>Its root go.mod gives the source <br>module paths.                                         |
|   target-branch   | string |   true   |          |                              Release branch the backport PR targets, <br>e.g. release-4.12. Its root go.mod gives <br>the target module paths.                                |

<!-- AUTO-DOC-INPUT:END -->

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT   |  TYPE  |                                                             DESCRIPTION                                                             |
|------------|--------|-------------------------------------------------------------------------------------------------------------------------------------|
| conclusion | string | fixed (a commit was made), unchanged (nothing to rewrite), skipped (same module paths, no go.mod, or missing input) <br>or failed.  |
|   reason   | string |                                               One-line explanation of the conclusion.                                               |

<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-backport-fix-imports
```

Runs the pytest suite in `test/`: the `go.mod` mapping, the import-hunk
resolver, and full runs against throwaway git repos pushed to a local bare
remote. No network and no tokens.

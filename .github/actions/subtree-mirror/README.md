# subtree-mirror

Mirror a monorepo subtree to a downstream OSS repository.

This action splits a subtree out of the calling monorepo and publishes it to a
branch on a separate OSS repo. It is built for the vCluster setup where
`vcluster-pro` holds the source of truth under
`staging/github.com/loft-sh/vcluster/` and `loft-sh/vcluster` is the public
mirror that external contributors open PRs against.

## Why the force push is guarded

The mirror branch (`main`) is replaced on every sync, so a naive force push
destroys any commit merged **directly** on the OSS repo — for example an
external contributor's PR, since contributors do not know about the private
monorepo. This action refuses to force-push when the OSS branch contains
anything the subtree is missing. It detects that condition with a **marker
ref** (the SHA we last mirrored) plus a **tree-equality** check, never with
commit ancestry — `git subtree split` produces a synthetic history whose graph
is unrelated to the OSS repo's, so ancestry checks do not apply.

Force-push proceeds only when one of these holds:

- the OSS branch does not exist yet (first push), or
- the OSS branch equals `marker-ref` (nobody touched the mirror since), or
- the OSS branch's content already equals the split we would push (an external
  commit was pulled back into the subtree by the back-sync), or
- `allow-divergent-force` is `true` (manual re-bless after reconciling).

Otherwise the action sets `diverged=true`, prints the offending diff, and exits
non-zero **without pushing**. The caller is expected to trigger the back-sync
and alert.

Release lines use `force: false` — a plain fast-forward-only push that creates
the branch if absent and fails loudly on any non-fast-forward update.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|         INPUT         |  TYPE  | REQUIRED |          DEFAULT          |                                                                                                     DESCRIPTION                                                                                                      |
|-----------------------|--------|----------|---------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| allow-divergent-force | string |  false   |         `"false"`         | Bypass the divergence guard and force-push <br>even if the OSS branch has <br>unmirrored commits. Use only after confirming <br>those commits are absorbed into the <br>subtree (manual re-bless). Force mode only.  |
|        branch         | string |   true   |                           |                                                                            Target branch on the OSS repo <br>(usually github.ref_name).                                                                              |
|         force         | string |  false   |         `"false"`         |                                                        true = marker-guarded force push (mirror branch). <br>false = fast-forward-only push (release lines).                                                         |
|     github-token      | string |   true   |                           |                                                            Token with write access to the <br>OSS repo. Used to build the <br>push remote; never logged.                                                             |
|      marker-ref       | string |  false   | `"refs/sync/mirror-head"` |                                                                    Ref on the OSS repo tracking <br>the last mirrored SHA. Force mode <br>only.                                                                      |
|       oss-repo        | string |   true   |                           |                                                                         Downstream OSS repository as owner/repo, e.g. <br>loft-sh/vcluster.                                                                          |
|    subtree-prefix     | string |   true   |                           |                                     Path of the subtree within this <br>repo, e.g. staging/github.com/loft-sh/vcluster. Requires a full-history <br>checkout (fetch-depth: 0).                                       |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|  OUTPUT   |  TYPE  |                                               DESCRIPTION                                                |
|-----------|--------|----------------------------------------------------------------------------------------------------------|
| diverged  | string | true when the OSS branch had <br>commits not present in the subtree <br>and the force push was refused.  |
|  pushed   | string |                          true when a push to the <br>OSS branch was performed.                           |
| split-sha | string |                     The subtree split SHA that was <br>(or would have been) pushed.                      |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

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

# On divergence, pull the external commits back, then alert.
- if: failure() && steps.mirror.outputs.diverged == 'true'
  env:
    GH_TOKEN: ${{ secrets.GH_ACCESS_TOKEN }}
  run: gh workflow run sync-from-oss.yaml --repo ${{ github.repository }}
```

### First-run / divergence recovery

On the first run the marker may be stale relative to the current mirror; if the
guard reports a false divergence, seed it once with the OSS branch's current
SHA, or run the caller via `workflow_dispatch` with `allow-divergent-force=true`
after confirming the OSS branch holds nothing the subtree is missing. After a
real divergence, run the back-sync so the external commits land in the subtree;
the next mirror then proceeds on its own via the tree-equality path.

## Tests

```bash
make test-subtree-mirror
```

Bats tests spin up real temporary git repos (a monorepo and a bare OSS remote)
and exercise every push/guard path locally — no network or tokens.

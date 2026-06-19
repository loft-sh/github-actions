# DEVOPS-1006: Loft Bot double-commenting on release issues

Root-cause analysis. Reported by Denise: ENG-8307 was re-commented "Now available
in stable release" on the latest vCluster 0.28 release, with two identical
comments. Her hypothesis was the new "None"/patch release type. That hypothesis
is correct, and the mechanism is below.

## Evidence

ENG-8307 (Loft Bot comments, from the Linear API):

| Tag | Comment 1 | Comment 2 | Gap |
|-----|-----------|-----------|-----|
| `v0.28.2-patch.1` | 2026-06-17 14:40:38 | 2026-06-17 16:28:54 | ~1h48m |
| `v0.30.4`         | 2025-12-17 17:20:59 | 2025-12-17 17:42:37 | ~21m  |

Both pairs are the **same tag**, so this is not the DEVOPS-874 wrong-previous-tag
case (which produces duplicates with *different* tags). Mapping comments to runs:

- `v0.28.2-patch.1`: vcluster release run published 14:15, `sync_linear` posted
  at 14:40. vcluster-pro published the same tag at 15:46, its `sync_linear`
  posted at 16:28. One comment per repo.
- `v0.30.4`: vcluster published 16:56:19 (comment 17:20), vcluster-pro published
  16:56:25 (comment 17:42). One comment per repo.

The "double comment" is **two repositories releasing the same version tag**,
each running its own Linear sync against the **shared** Linear issue.

## Why the deployed `linear-release-sync` action is not the culprit here

The release-branch jobs do not use the pinned action binary. The `sync_linear`
job in `release.yaml` **at tag `v0.28.2-patch.1`** (the old 0.28 branch) runs the
inline predecessor:

```yaml
sync_linear:
  steps:
    - uses: actions/checkout@v5
    - uses: actions/setup-go@v6
    - name: Update linear issues
      run: go run . -release-tag="${{ needs.publish.outputs.release_version }}"
      working-directory: hack/linear-sync   # vcluster-internal, pre-extraction
```

GitHub runs a `release`-triggered workflow from the tag's ref, so a patch/backport
tag on an old branch always runs that branch's old workflow and old
`hack/linear-sync` code, never the migrated action on `main`. Confirmed: vcluster
`main` no longer has `hack/linear-sync` (migrated to the extracted action);
vcluster-pro `main` uses the action too, but its `v0.28.2-patch.1` tag still runs
`go run hack/linear-sync`.

The deployed `linear-release-sync/v1` binary (vcs.revision `2931093`, semver
v3.4.0) is correct: `isStableRelease("v0.28.2-patch.1") == false`, so it would
*skip* the prerelease and never post. It was a red herring.

## The three defects in the old `hack/linear-sync` (release branches)

1. **`isStableRelease` is a substring blocklist that omits `-patch`.**
   ```go
   preReleaseSuffixes := []string{"-alpha", "-beta", "-rc", "-dev", "-pre", "-next"}
   ```
   `v0.28.2-patch.1` matches none, so it is classified **stable** -> the
   `alreadyReleased && isStable` branch fires the "Now available in stable
   release" comment on already-released issues. This is exactly Denise's "None"
   release-type intuition: the patch suffix is the new release type, and the old
   classifier does not recognize it. (The extracted action uses Masterminds
   `Prerelease()` instead, which treats `-patch.N` as a prerelease.)

2. **No comment deduplication.** The old `linear.go` has no `ListIssueComments`
   / `hasStableReleaseComment` guard at all; it posts unconditionally. So a
   second run, or a second repo releasing the same tag, always re-comments. The
   dedup was added later, only to the extracted action.

3. **Over-broad previous-tag.** For `v0.28.2-patch.1`, `LastStableReleaseBeforeTag`
   resolved the predecessor to `v0.27.3`, producing a `v0.27.3..v0.28.2-patch.1`
   compare range of 91 PRs / 72 issues. That re-includes everything already
   shipped in 0.28.0/0.28.1/0.28.2, so already-released issues like ENG-8307 are
   re-touched on every backport patch.

Multiplier: vcluster and vcluster-pro both cut the same tags and both run their
own old `hack/linear-sync` against the same Linear issues -> one spurious comment
per repo.

## Blast radius

Any vcluster / vcluster-pro **release branch** cut before the migration to the
extracted action still carries `hack/linear-sync` + the old `release.yaml`. Every
patch/backport release on those branches reproduces this. `-patch.N` tags hit all
three defects; plain stable backports (e.g. v0.30.4) still hit defects 2 and 3
(cross-repo, no-dedup duplication).

## The real design issue: tag-string parsing vs. release intent

Both the old and new classifiers re-derive "is this a releasable version?" from
the **tag string**, and both get the patch scheme wrong in opposite directions:

- old `hack/linear-sync`: substring blocklist -> `-patch.N` looks stable -> over-fires
- extracted action: Masterminds `Prerelease()` -> `-patch.N` looks prerelease -> skips

But GitHub already records the author's intent on the release object, and it is
correct for every tag type vCluster ships:

| Tag type | GitHub `prerelease` | Intent |
|----------|---------------------|--------|
| `v0.35.0`, `v0.34.4` stable | `false` | release |
| `v0.28.2-patch.1` patch / "None" | `false` | release |
| `v0.35.0-rc.9`, `-alpha.8` | `true` | not a release |

`-patch.N` is a semver **prerelease** (precedence below `v0.28.2`) even though it
ships *after* v0.28.2. That mismatch is what fights every semver-aware tool here
(this action, goreleaser previous-tag, the homebrew downgrade guard).

## Recommended solution

1. **Classify by the GitHub `prerelease` flag, not the tag string.** The action
   already fetches the release object; gate the sync on `release.IsPrerelease`
   instead of `isStableRelease(tag)`. This makes `-patch.N` sync and `-rc.N` skip,
   matching intent, and future-proofs against new suffixes. (The `-next` filter in
   the caller workflow becomes redundant.)
2. **Migrate release-branch `sync_linear` to the extracted action** on active
   vcluster + vcluster-pro release branches. This deletes the old inline code path
   (no-dedup, substring blocklist) and gives release branches the maintained logic
   with tag-scoped dedup, which kills the cross-repo duplicate.
3. **Scope the compare range to the patch delta.** For `v0.28.2-patch.1` the
   predecessor should be `v0.28.2`, not `v0.27.3`. Pass `previous-tag` explicitly
   from the caller for patch releases, or fix predecessor selection for
   prerelease-suffixed-but-published tags. The correct range is the cure for
   re-announcing already-released issues; dedup is only the safety net.

Open question for Denise (release-type owner): is `-patch.N` the intended
long-term scheme? A normal patch bump (`v0.28.3`) or build metadata
(`v0.28.2+patch.1`, equal precedence rather than lower) would avoid the semver
prerelease trap entirely. If `-patch.N` must stay, the `prerelease`-flag approach
above is the robust fix.

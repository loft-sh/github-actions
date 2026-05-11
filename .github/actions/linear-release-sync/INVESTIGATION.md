# Investigation: ENGUI-494 received an "available in v4.8.2" comment after shipping in v4.8.0

DEVOPS-874 / triggered by [comment on ENGUI-494](https://linear.app/loft/issue/ENGUI-494/missing-padding-on-collapsible-section-headers-eg-apps-and-objects#comment-559b6cea).

## Summary

`linear-release-sync` picks the wrong "previous tag" when a repository maintains
multiple stable release lines in parallel. The compare range used to enumerate
PRs (`prevTag..currTag`) then spans the wrong git ancestry, so PRs that already
shipped on an earlier patch of the current line get re-attributed to the new
release and receive an extra "Now available in stable release vX.Y.Z" comment.

## Reproduction (loft-sh/loft, v4.8.2)

Release timeline around 2026-04-28 (from `gh release list --repo loft-sh/loft`):

| Tag      | Published (UTC)        |
|----------|-----------------------|
| v4.8.1   | 2026-04-02 16:04      |
| v4.6.3   | 2026-04-28 22:03      |
| **v4.8.2** | **2026-04-28 22:05** |
| v4.5.6   | 2026-04-28 22:21      |
| v4.7.2   | 2026-04-29 00:11      |

At the moment v4.8.2 published, v4.6.3 was the most recently created stable
release. `LastStableReleaseBeforeTag(v4.8.2)` returned **v4.6.3** rather than
v4.8.1, because the lookup orders by GitHub release creation time, not semver.

`FetchAllPRsBetween(prevTag=v4.6.3, currTag=v4.8.2)` then resolves to the
commits reachable from v4.8.2 but not from v4.6.3 — i.e. everything unique to
the 4.8 line, including 4.8.0 and 4.8.1. The PR that referenced ENGUI-494 (and
landed in v4.8.0) was in that set.

In `MoveIssueToState` (`src/linear.go:269-337`):

1. ENGUI-494 was already in the `Released` state (set during the v4.8.0 sync),
   so the function entered the "already released + stable release" branch
   (`linear.go:284-300`).
2. `hasStableReleaseComment(comments, "v4.8.2")` returned false — the dedup
   guard is **per-tag** (only matches `"Now available in stable release v4.8.2"`),
   so any prior v4.8.0 / v4.8.1 comments do not block a v4.8.2 comment
   (`linear.go:414-422`).
3. A new comment "Now available in stable release v4.8.2 (released 2026-04-28)"
   was posted.

Strict filtering (`pr.go:98-120`) did not help: the v4.8.0 PR was merged long
before v4.8.2's `PublishedAt`, so it passes the `MergedAt.After(release)`
filter.

## Root cause

`LatestStableSemverRange` (`src/changelog/releases/releases.go:45-107`)
iterates GitHub releases ordered by `CREATED_AT DESC` and returns the first
one whose semver matches the constraint (`< 4.8.2`). For a single linear
release history this happens to be the semver predecessor, but for the loft
release pipeline — which actively maintains 4.5.x, 4.6.x, 4.7.x, and 4.8.x in
parallel — any patch on a *different* line cut between v4.8.1 and v4.8.2 will
be picked as the "previous tag". v4.6.3 (cut two minutes before v4.8.2) is the
exact failure case here.

The README claims "Strict time-based filtering: only includes PRs merged
before the release was published" but that filter is downstream of the wrong
compare range. By the time it runs, the 4.8.0 PR has already been included.

The action has no notion of a release *line* (major.minor), and `compare()` in
the GitHub GraphQL API does not respect branch ancestry semantics relative to
the previous tag — it just returns commits reachable from `headRef` that are
not reachable from `qualifiedName`.

## Why the dedup guard does not save us

`hasStableReleaseComment` only matches comments that start with
`"Now available in stable release <exact-tag>"` (`linear.go:414-422`). This is
intentional — cherry-picks released in a later stable should get their own
comment. But that intent assumes the only PRs reaching the function are the
ones genuinely new in that release. Once the compare range is wrong, the
dedup guard is the wrong dimension: it deduplicates across *runs of the same
release*, not across *prior releases that already commented on this issue*.

## Scope: how many issues were affected by v4.8.2

Any Linear issue whose PR landed in **v4.8.0 or v4.8.1** and that was in the
`Released` state at the time of v4.8.2's sync run would have received a
spurious "Now available in stable release v4.8.2" comment. That set is roughly
"every issue closed in v4.8.0 and v4.8.1 except those that had already moved
out of Released by 2026-04-28 22:05Z."

Future risk: the same misattribution will happen on every patch release as
long as another release line ships near the same time. v4.7.x and v4.5.x line
cuts on 2026-04-28 mean v4.8.x sync is the most exposed, but the bug is
structural, not specific to v4.8.2.

## Recommended fixes (ranked, separate PR)

1. **Sort previous-stable lookup by semver, not by creation date.**
   In `LatestStableSemverRange`, paginate all stable releases, then sort by
   semver descending client-side, then return the first match of the
   constraint. This is the minimal correct fix.

2. **Prefer same-line predecessor.** Given `tag=X.Y.Z`, look up the highest
   stable in `>= X.Y.0, < X.Y.Z` first; if none, fall back to highest stable
   `< X.Y.0`. This matches operator intent more cleanly and bounds the compare
   range to the same line for patch releases.

3. **Make the caller pass `previous-tag` explicitly.** The release workflow
   knows the predecessor at release time (the prior tag on the same branch).
   Adding `previous-tag: ${{ needs.publish.outputs.previous_tag }}` to the
   caller workflow avoids the lookup entirely. This is the safest operational
   mitigation in the short term while the action is patched.

4. **Tighten the "already released, stable" guard.** Even with a correct
   compare range, consider checking for any prior `"Now available in stable
   release "` comment (without tag specificity) and skipping if one exists
   for a tag >= current minor. That would have suppressed the duplicate
   regardless of compare-range correctness, at the cost of breaking the
   cherry-pick-comments use case the per-tag dedup was designed to support.
   Option (4) is best paired with explicit cherry-pick detection rather than
   added blindly.

## Suggested next step

File a follow-up Linear issue ("Fix `LastStableReleaseBeforeTag` to use semver
ordering; pass explicit `previous-tag` from loft release workflow") and apply
fix (3) as an immediate hotfix while (1) is implemented.

Optionally add a recurring audit (separate routine) that walks recent stable
releases and asserts every Linear issue's "Now available in stable release
vX.Y.Z" comment ordering — to detect regressions of this class.

# Release notes

Writes the GitHub release bodies for a monorepo release that also publishes
an OSS subtree as its own repository, as `loft-sh/vcluster-pro` does for
`loft-sh/vcluster`. Both releases list the same changes in two sections:

- **Open source**: commits that touch the subtree, picked by the same
  `rev-list` [`oss-commit-sync`](../oss-commit-sync/README.md)'s export runs.
- **Commercial**: every other commit.

## Why the monorepo computes both bodies

The OSS release tag is a parentless snapshot of the subtree, built by the
release pipeline. It shares no history with the earlier tag, so GitHub's
`generate-notes` on the OSS repository cannot bound the range: it either
lists the whole repository history or rejects the previous tag with
`400 Invalid previous_tag parameter`. Comparing two OSS tags shows nothing for
the same reason. The monorepo has the real history, so both bodies come from
one first-parent walk there.

## How it works

1. The base is `previous-tag` when given. Otherwise it follows the rules in
   `release-lib/release_tags.py`, which
   [`release-summary`](../release-summary/README.md) uses too: a stable tag
   (no prerelease part, or `-patch` / `-patch.N`) compares with the highest
   earlier stable tag on any branch, and a pre-release with the nearest
   earlier `v*` tag. A `-next` tag is never a base.
2. It lists the first-parent commits in that range, oldest first, and drops
   commits whose subject starts with `docs:` or `test:`, the goreleaser
   changelog filters it replaces. Scoped forms such as `test(e2e):` stay.
3. It writes two files:
   - `notes-file`, for the monorepo release: subjects as committed, a link to
     each commit, and a compare link.
   - `public-notes-file`, for the OSS release: no refs into the monorepo.
     `#N` and `GH-N` refs number monorepo PRs and link unrelated PRs on the
     OSS repository, and the monorepo's `owner/repo` followed by `#`, `@` or
     `/`, or any URL naming it, points into a private repository, so all of
     them are dropped, along with parentheses that held nothing else.
     No compare link, because the OSS tags cannot be compared.

   In the public file each subject is inline code, which GitHub renders as
   it is: whatever the stripping leaves cannot link, mention, embed or
   format anything, so the only links are the OSS commit links the action
   adds. A run of more than three backticks shrinks to three, so the span's
   fence stays one GitHub closes. In the monorepo file subjects stay
   markdown as committed, as goreleaser listed them; a word joiner follows
   each `@` GitHub would read as a mention, and an entity with its
   semicolon such as `&#x40;`, or in a subject holding HTML any `&#`, is
   escaped so it cannot become one, so a subject notifies nobody and adds
   nobody to the release's contributors.

   In both files a subject is one line: control characters and line
   separators, such as a carriage return, which CommonMark reads as a line
   ending, become spaces, and so do bidi controls, which could show the
   commit links after a subject reversed. A subject longer than 300 characters is cut with
   `…`. GitHub caps a PR
   title at 256, so a squash subject with its ` (#N)` always fits.

A commit imported from the OSS repository carries an `Oss-Commit:` trailer.
It is read as `oss-commit-sync`'s `trailer_scan` reads it, from the message
lines and from git's own trailer block, and the tests check the two agree. Its subject can
hold both the OSS PR number and the number of the monorepo PR that merged
the import, and git cannot tell the two apart. Both bodies drop those refs
and link the OSS commit from the trailer instead, whose page shows its PR. A
bulk sync that carries several trailers links none of them.

GitHub limits a release body to 125,000 characters, and goreleaser cuts a
longer one at that many bytes. When a body would pass 125,000 bytes, both
bodies drop the same oldest entries until each fits, and say how many they
left out.

The step fails with an `::error::` line when the notes cannot be written: a
shallow checkout, a missing tag, a `subtree-prefix` that is not a directory
below the root at the tag, no earlier tag to compare against, or any other
error. It runs before anything is published, so a failure costs a re-run
rather than a release with an empty or wrong body. A re-run does not change
the body of a release that already exists: goreleaser keeps existing release
notes, and so does vcluster-pro's OSS release step, which tolerates "already
exists".

## Usage

Run it in the release job before the release is created, from a checkout
with full history and tags.

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    fetch-depth: 0
    fetch-tags: true
    persist-credentials: false
- name: Write release notes
  id: notes
  uses: loft-sh/github-actions/.github/actions/release-notes@release-notes/v1
  with:
    version: ${{ github.ref_name }}
    subtree-prefix: staging/github.com/loft-sh/vcluster
    repository: ${{ github.repository }}
    oss-repository: loft-sh/vcluster
- uses: goreleaser/goreleaser-action@<sha> # v7
  with:
    args: release --release-notes ${{ steps.notes.outputs.notes-file }}
# Pass steps.notes.outputs.public-notes-file to whatever creates the OSS
# release. vcluster-pro's release.yaml pushes the snapshot tag first, then
# runs gh release create --notes-file with --latest=false, adds --prerelease
# for a suffixed tag, and tolerates a release that already exists.
```

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT      |  TYPE  | REQUIRED | DEFAULT |                                                                                                                              DESCRIPTION                                                                                                                              |
|----------------|--------|----------|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| oss-repository | string |   true   |         |                                                                                OSS repository owner/name, for links to <br>the OSS commits that commits imported <br>from it replay.                                                                                  |
|  previous-tag  | string |  false   |         | Tag to compare against. Leave empty <br>to derive it: a stable tag <br>(no prerelease part, or -patch / -patch.N) compares with the highest earlier <br>stable tag on any branch, a <br>pre-release with the nearest earlier v* <br>tag that is not a -next <br>tag.  |
|   repository   | string |   true   |         |                                                         Monorepo owner/name, for commit and compare <br>links in the monorepo body. The <br>checkout must be this repository with <br>full history and tags.                                                          |
| subtree-prefix | string |   true   |         |                                  Path of the OSS subtree in <br>the monorepo, as oss-commit-sync takes it, <br>e.g. staging/github.com/loft-sh/vcluster. Must be a directory <br>below the repository root at the <br>release tag.                                    |
|    version     | string |   true   |         |                                                                                                             Release tag. Must exist in the <br>checkout.                                                                                                              |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|      OUTPUT       |  TYPE  |                                           DESCRIPTION                                            |
|-------------------|--------|--------------------------------------------------------------------------------------------------|
| commercial-count  | string |                        Number of entries in the commercial <br>section.                          |
|    notes-file     | string |    Path of the monorepo release body, <br>with PR refs, commit links and <br>a compare link.     |
| open-source-count | string |                        Number of entries in the open <br>source section.                         |
|   previous-tag    | string |                              Tag the release was compared against.                               |
| public-notes-file | string | Path of the OSS release body: <br>no monorepo PR refs or commit <br>links, and no compare link.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-release-notes
```

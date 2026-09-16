# OSS Mirror Staleness

Is the code on the public mirror the code we have?

## Why this exists

`oss-commit-sync`'s export direction fails closed and stops when it cannot safely
push. That is the right behaviour, but it is invisible. The export runs on push,
so a failure leaves a red run in the Actions tab where nobody is looking, and the
downstream mirror quietly stops advancing.

`loft-sh/vcluster` went 18 days and 20 commits behind that way. Every export run
in that window was red. Nothing said so, and it surfaced only because somebody
asked why a GitHub compare view between two release tags was empty.

This check does not read run history at all, which is the point. Comparing the
refs themselves also catches the failure modes a run-status alert structurally
cannot see:

- the workflow stopped triggering (a path filter or branch pattern no longer
  matches, the workflow was disabled, the branch was renamed)
- the export is green but the mirror is behind for some other reason
- the export never ran on a branch that nobody thought to wire up

## How it decides

First, the direct question: if the mirror's tree is identical to the subtree tree
at the branch tip, the mirror is current and nothing else needs asking. This
short-circuit matters because it is immune to every rule below.

Otherwise, the record walk. Every commit the export creates carries a
`Monorepo-Commit` trailer naming the monorepo commit it came from. The check
collects those records from the OSS branch, then walks the monorepo branch's
subtree-touching commits newest first. The first commit that is recorded is the
**frontier**; everything newer than it is **backlog**.

Trailer reading is permissive about capitalisation and matches abbreviated values
by prefix, because a record we fail to read invents backlog that is not there and
a false alarm costs more trust than it buys. It stops at git's trailer block: the
mirror is public and takes outside contributions, so a column-zero
`Monorepo-Commit:` line in a contributor's message body would be read as a record
we wrote, and a record is what ends the walk. Nothing legitimate is lost by
refusing, because the export writes its trailer with `interpret-trailers
--no-divider` and pushes straight to the mirror, with no PR and no squash in
between that could orphan it out of the block.

That narrows the forgery rather than ending it, and it is worth being plain about
which half is which. Closed: the line written anywhere in a PR description, which
a squash then leaves in the body — free to write, and the reason this key is read
from the block at all. Open: the same line written as a real trailer, in the last
paragraph, where git reads it and nothing at this layer distinguishes it from a
record we wrote. `oss-commit-sync` states the same exposure for the same key and
says what closing it would take; this check inherits it rather than adding to it.

### Commits that will never carry a record

The exporter deliberately skips two classes of commit, and neither ever gets a
`Monorepo-Commit` record on the mirror:

- commits carrying an `Oss-Commit` trailer, which originated on OSS and were
  imported into the subtree
- commits whose patch applies as a no-op, because the content is already there

Counting those as backlog would alert forever on a mirror that is perfectly
current, and an imported community contribution is the common case. The walk
applies the first rule itself; the second is covered by the tree short-circuit
above, which is why that comes first — and why `exclude-paths` matters. The
export holds the two trees to agree everywhere *except* those paths, so on a repo
that configures them a short-circuit demanding whole-tree equality never fires,
the no-op class stops being covered by anything, and a no-op commit on a quiet
release branch becomes backlog that no export can ever drain. Pass the same list
here that `oss-commit-sync` is given.

`Oss-Commit` is read exactly as the exporter reads it — no looser and no
stricter, which is the part that is easy to get wrong. Looser hides a commit the
export still owes the mirror. Stricter is not the cautious choice it looks like:
a record the exporter reads makes it skip the commit and record nothing, forever,
so failing to read that same record parks the commit in the backlog permanently
and alerts on a branch that is current. Matching it means reading the union the
exporter reads: git's own trailer block, which accepts a space before the colon
and unfolds a value split across lines, plus a body scan for records a squash
orphaned out of the block. An indented line on its own is still not a record,
because git does not read one either.

A merge commit is the opposite case again, and is counted, loudly. The exporter
refuses merges outright rather than skipping them, so one in the backlog is the
hardest stall there is: it will not drain no matter how long it waits. It needs
saying because `git diff-tree` prints nothing for a merge, which makes it look
exactly like an empty commit unless you ask about the parents first.

### The one case this cannot see

If a commit and its revert are both un-mirrored, the trees agree again and the
short-circuit reports in sync, because by content it is. That is the right answer
to the question asked, but it means a dead exporter goes unnoticed until the next
commit that actually changes something. So when the trees match and no export
recorded the newest commit it owed a record for, the check sets
`export-unconfirmed` and says so, rather than staying quiet, and leaves `frontier`
empty: that path never found a record, and answering with the commit would hand a
caller the dead export as its healthiest signal.

It gets its own output because nothing else can carry it. The content is current,
so `stale` is false by definition and `degraded` is not true either — the check
answered the question it was asked. A warning in the log of a scheduled run is
exactly the invisibility this action exists to end, so a caller that wants the
signal has to be able to gate on it.

The commit asked about is the newest one the export actually owed a record for,
not the branch tip: most commits on the monorepo branch never touch the subtree,
and an imported commit is skipped by design, so asking about either would print
this on nearly every healthy run.

It can still be wrong in one direction, and the shape is worth knowing. The
exporter's other skip class — a commit whose patch applies as a no-op because the
content reached the mirror another way — leaves no record either, and unlike an
import it carries no trailer to recognise it by. On the content-match path
nothing distinguishes it from a dead export: the trees agree in both cases, which
is the whole reason that path exists. So a change applied by hand on both sides,
rather than imported through `sync-from-oss`, sets `export-unconfirmed` until the
next subtree commit lands. Going through the import direction avoids it, since
that stamps `Oss-Commit`.

One route to `stale` skips the threshold: a backlog deeper than `scan-limit` with
no frontier anywhere in it. At that depth the grace the threshold buys has been
spent several times over, and the ages of the commits in the window say nothing
about how far back the real backlog starts. That route sets `degraded` as well,
so a caller following the advice above sees it either way.

## Staleness is measured on the oldest waiting commit

Backlog alone is not staleness. A commit merged two minutes ago has not had time
to mirror, and alerting on it would fire on every normal merge.

So `stale` is judged on the age of the **oldest** commit still waiting, not the
newest. A fresh commit landing on top of a week-old stall does not reset the
clock and hide it. Set `max-age-hours` above a normal export time plus the review
time a back-sync PR realistically needs.

## Alert on `stale` OR `degraded`

The check never exits non-zero. Silence is the bug it exists to fix, so it must
not become a new way to fail quietly: when it cannot answer, it says so with
`degraded=true` and still exits 0.

**A caller that alerts only on `stale` reintroduces the original bug.** "I could
not tell" and "it is fine" are different answers. `degraded` covers an
unreachable OSS branch, a shallow checkout, unreadable records, a bad threshold,
and a backlog deeper than `scan-limit`.

Every output carries a value on every path, including degraded ones, so a caller
reading `stale` after a degraded run gets a real answer rather than an empty
string that compares equal to nothing.

## Requirements

- `fetch-depth: 0` on the checkout. A shallow clone would put the frontier at the
  bottom of the clone, which reads as "in sync"; the check refuses and degrades
  instead.
- A token that can fetch the OSS branch. Read-only is enough, so prefer
  `github.token` over the write-capable PAT the export needs.

## Usage

```yaml
- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  with:
    fetch-depth: 0
    persist-credentials: false

- id: staleness
  uses: loft-sh/github-actions/.github/actions/oss-mirror-staleness@oss-mirror-staleness/v1
  with:
    subtree-prefix: staging/github.com/loft-sh/vcluster
    oss-repo: loft-sh/vcluster
    branch: ${{ matrix.branch }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
    max-age-hours: '24'
    # The same list the export is given, or the content short-circuit never
    # matches and the skipped-commit classes turn into permanent backlog.
    exclude-paths: |
      .github/workflows/release.yaml
      .github/workflows/push-head-images.yaml

- name: Report
  if: steps.staleness.outputs.stale == 'true' || steps.staleness.outputs.degraded == 'true'
  run: echo "the mirror needs attention"
```

## Relationship to the other sync checks

| check | question it answers | fires on |
| -- | -- | -- |
| `oss-commit-sync` export | can I safely push what is new? | every push touching the subtree |
| `oss-commit-sync` health | are the trailers still telling the truth? | trailer hygiene, explicitly not outages |
| `oss-mirror-staleness` | is the mirror carrying what we have? | a schedule, independent of any run |

The health direction opens by disclaiming exactly this job ("Nothing here is an
outage"). It is scoped to provenance hygiene and should stay that way; mirror
currency is a different question and wants its own signal.

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|     INPUT      |  TYPE  | REQUIRED | DEFAULT |                                                                                                                                                                                                           DESCRIPTION                                                                                                                                                                                                           |
|----------------|--------|----------|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     branch     | string |   true   |         |                                                                                                                                                                                         Branch to check, same name on <br>both repos.                                                                                                                                                                                           |
| exclude-paths  | string |  false   |         |     Newline-separated paths (relative to the OSS repo root) the export never <br>mirrors. Pass the same list given <br>to oss-commit-sync: it holds the two <br>trees to agree everywhere else, so <br>without this the content comparison here <br>never matches and the check falls <br>back to the commit walk, which <br>counts the commits the exporter skips <br>without a record as backlog that <br>never drains.       |
|  github-token  | string |   true   |         |                                                                  Token used to build the OSS <br>remote URL; never logged. Read-only is <br>enough: this check only fetches the <br>OSS branch, so give it the <br>least-privileged token that can (github.token suffices for a public OSS repo) rather <br>than the write-capable PAT the export <br>needs.                                                                    |
| max-age-hours  | string |  false   | `"24"`  | How long the oldest un-mirrored commit <br>may wait before the mirror counts <br>as stale. Measured on the OLDEST <br>commit still waiting, not the newest, <br>so a commit that landed moments <br>ago never alerts while a genuine <br>stall always does. Keep it above <br>the time a normal export takes <br>plus the review time a back-sync <br>PR realistically needs, or the check <br>cries wolf on every divergence.  |
|    oss-repo    | string |   true   |         |                                                                                                                                                                              Downstream OSS repository as owner/repo, e.g. <br>loft-sh/vcluster.                                                                                                                                                                                |
|   scan-limit   | string |  false   | `"500"` |                                                                                  How many commits to read on <br>each side before giving up and <br>reporting degraded. Exports are append-only and <br>frequent, so the frontier sits near <br>the tip; this bound only exists <br>to keep the check off years <br>of pre-merge OSS history.                                                                                   |
| subtree-prefix | string |   true   |         |                                                                                                                                                 Path of the subtree within this <br>repo, e.g. staging/github.com/loft-sh/vcluster. Must match the <br>prefix the export uses.                                                                                                                                                  |

<!-- AUTO-DOC-INPUT:END -->

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|           OUTPUT            |  TYPE  |                                                                                                                                                                                                                                      DESCRIPTION                                                                                                                                                                                                                                      |
|-----------------------------|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|        backlog-count        | string |                                                                                                                                                                                     Number of subtree-touching commits on the <br>branch that the mirror does not <br>carry. Zero means in sync.                                                                                                                                                                                      |
|          degraded           | string |                                                                                                       True when the check could not <br>determine the answer (no OSS branch, shallow checkout, unreadable records, backlog deeper than scan-limit). Never treat <br>this as healthy; it is the <br>fail-safe that keeps an unanswerable check <br>from reading as a green one.                                                                                                        |
|     export-unconfirmed      | string |                                                                             True when the mirror content matches <br>but no export recorded the newest <br>commit the export owed a record <br>for. Not staleness: the content is <br>current, so stale stays false. It <br>is the one shape a dead <br>export takes that produces no other <br>signal, so gate on it alongside <br>stale and degraded.                                                                               |
|          frontier           | string |                                                                                                               The newest monorepo commit the mirror <br>has a record of. Empty when <br>none was found within scan-limit, which <br>also sets degraded, and empty on <br>a content match whose tip nothing <br>recorded, since no record was located <br>there either.                                                                                                                |
|      oldest-unmirrored      | string |                                                                                                                                                                                   The oldest subtree commit the mirror <br>does not carry, i.e. where the <br>backlog starts. Empty when in sync.                                                                                                                                                                                     |
| oldest-unmirrored-age-hours | string |                                                                                                                                                                       How long that oldest un-mirrored commit <br>has been waiting, in whole hours. <br>This is the figure compared against <br>max-age-hours.                                                                                                                                                                        |
|           oss-tip           | string |                                                                                                                                                                                                                        The OSS branch tip the check <br>read.                                                                                                                                                                                                                         |
|            stale            | string | True when the mirror is behind <br>and the oldest un-mirrored commit has <br>been waiting longer than max-age-hours. One <br>exception, unconditional: a backlog deeper than <br>scan-limit with no frontier in it <br>at all sets this whatever the <br>ages are, because at that depth <br>the grace the threshold buys is <br>already spent. That case sets degraded <br>too. Alert on this OR on <br>degraded: a check that could not <br>answer is not a check that <br>passed.  |

<!-- AUTO-DOC-OUTPUT:END -->

# QA review gate

Turns the review panel's QA verdict into the `qa-review` check-run on the pull
request's head commit, opens the `qa-test-run` check-run next to it, and lets a
tech lead override both or a member ask for a person with one comment (ENGQA-1983).

The panel (loft-sh/ai-agents, `pr-review`) posts a COMMENT review as `loft-bot`
whose body ends with one marker line:

```
<!-- qa-review verdict=block classes=a:0,b:1,c:2,d:0 head=<40-char sha> base=<base branch> -->
```

| Verdict | `qa-review` | Meaning |
|---|---|---|
| `block` | failure | a confirmed class a/c/d finding: a test is needed, missing, or the product has a gap |
| `pass` | success | nothing blocks |
| `needs_human` | action_required, PR assigned to its author | a class b finding (an open question alone leaves the verdict a pass); the author answers the panel, or tags QA with `/qa-review human` |
| `not_run` | action_required | the QA lanes did not run on this PR; neutral would count as passed once the check is required |

A marker whose `head` is not the PR's current head is ignored, so an old review
never grades a new push. A marker whose `base` is not the base the PR targets when
the gate writes is ignored too: a panel run that started before a retarget graded the
old diff, and the panel runs again on the new one.

The same review event opens `qa-test-run` on that head, unless one is there
already: success when the PR adds no e2e spec, action_required naming the new
specs otherwise, until an e2e run reports (below). So both check-runs can be
required without blocking a PR that adds no spec.

Callers trigger `bot` mode on `pull_request_target`, not `pull_request`: a `pull_request`
run for a fork PR gets a read-only token and could not write the check-runs, and the gate
never checks out PR code (it checks out its own action only), which is what makes the
target trigger safe here.

A PR that touches no QA-owned path (`qa-paths`, by default the top-level `e2e*/` trees,
`staging/github.com/loft-sh/vcluster/e2e/` and the `.github/workflows/e2e*.yaml` files, the
same paths the dispatcher starts the panel on, matched the same way: a star stays inside one
path segment, `**` spans any depth, and a file under a `vendor` segment never counts) gets
both check-runs as success at once, titled "out of scope", on every push. The files are
those between the event's own base and head SHAs, never the PR's current files, so a queued
or rerun job cannot grade an older SHA by a newer diff; a compare at its cap (300 files)
falls back to the paginated PR files list while the PR still sits on the event's head and
base (checked before and after paging, and the list must be complete: the PR files API stops
at 3000), and otherwise leaves the decision to the panel or an override. The check names the
base it graded, and a retarget (`pull_request_target` `edited` with a base change, same
head) grades again: a head that is now in scope gets both checks back as `action_required`
until the panel or an override decides, so callers list `edited` among their types. The
panel's verdict replaces whatever the scope check wrote on `qa-test-run` (a pass or that
placeholder) with its normal test-run decision (green when the PR adds no spec, waiting for
an e2e run otherwise). Every run the gate writes carries the base it graded against in its
external id (`<kind>^<base>`; an override, a bot pass and a request for a person carry
none), so a retarget replaces a verdict, an opener or an e2e result graded against the old
base, or one that records no base (written before the gate recorded it), and keeps one
for the new base; an override or a request for a person written back then carries no
external id either, and the gate knows it by its title, so it stays; an override, a bot pass or `/qa-review human` stays,
whatever order the jobs ran in. The same ownership rule holds for every scope write
(`opened`, `reopened`, the sweep): the scope check never writes over a result for the
current base, a request for a person, an override or a bot pass. A fresh panel verdict
likewise replaces a `qa-test-run` result from another base, or with no recorded base,
with its own opener, and an e2e
run combines only tree results graded against the same base. A PR-triggered e2e run
tests the merge commit of the head and the base at that moment, so its `run-name` must
name that base (`... onto <base-ref>`, from `github.event.pull_request.base.ref`): a run
that names another base than the PR now targets, or none, is not credited, and a new run
grades the PR. A `/test-e2e` dispatch checks out the head alone, so its report holds for
any base. A retarget whose diff cannot be listed (the compare cap) withdraws the pass the same
way. The sweep grades each PR as it is at that moment, not as the open-PR list captured it
(the missing checks are counted on the current head), and checks the base again after
writing. Every gate job that writes to a head queues on that head (the tested commit for an
e2e run, the PR head for a PR event or a panel verdict), so a verdict or an e2e result
cannot land between a retarget job's read and its write; the sweep runs outside those
queues, so every scope write re-reads the head afterwards and copies a verdict or result
that landed meanwhile onto its own run, ownership included. The post-write regrade stays on
the head the job queued for: a head that moved on is graded by its own event. A scope pass
is published only while the PR still targets the graded base, and the job checks the base
once more after writing, so a retarget that overtakes a queued `opened` job cannot leave a
pass on a head that is now in scope. A trusted bot PR whose exemption was declined (a head
the bot did not push, or a bot push on a head the gate had not passed) never takes this
pass: it goes to review whatever it touches. The panel never runs on such a PR, so without
this a required check would block Renovate, version bumps and every code-only change. A PR
that does touch one of those paths gets nothing from this step: the panel's verdict and the
e2e report grade it.

Before the ruleset goes live, run the caller's `workflow_dispatch` once with no `pr-number`
(mode `sweep`): it lists every open PR whose current head lacks `qa-review` or `qa-test-run`
from GitHub Actions (the source the ruleset requires) and starts one run of the caller per
such PR, with that PR's number as `pr-number`. Each of those runs queues on the PR's head
like every other writer and gives the PR the same QA-scope pass it would have got on
`opened`, creating only the missing check (a retry after a partial write completes the
pair). A run whose PR is a trusted bot PR on a later head, or touches a QA-owned path, ends
with a warning: that PR needs `/vcluster-review` from a person or `/qa-review override`
before the ruleset is enabled. A per-PR run grades only while the PR still sits on the head
it queued for (`queued-sha`); a PR that moved on is left to that head's own event. In the
reusable workflow the listing is its own job, the one job with `actions: write`; the gate
job keeps `actions: read` on every event.

Every read of a check-run keeps only the runs GitHub Actions published, the source the
ruleset requires: an override, a bot pass, a tree result or a verdict that another app
wrote under the gate's external ids never counts and is never copied onto a gate run.

A trusted bot PR (`bot-prs`: a login and the branch prefix it opens PRs from, by
default `loft-bot` from `backport/` and `vcluster-qa-bot[bot]` from `flake-fixer/`)
was reviewed before it was opened: a backport on main, a flake-fixer PR by the QA
agent itself. On its `opened` event (mode `bot`) both check-runs complete as success
at once on the opened head and on the bot's import fix, when that fix builds on a head
this gate already passed (the import fix's job waits up to five minutes for the opened
head's pass, since the two jobs run in either order) (the bot commits on the branch tip, so a person's edit
underneath would ride along), and the repo's auto-approve workflow can approve it
without waiting on the panel. Any other head has no check-runs until the panel's verdict
and the e2e report grade it like any other PR.
(Commit authorship cannot tell the two apart: a bot backport keeps the original
author.)

An override is final for its head: a later e2e result or panel verdict on the same commit
does not replace it (the gate skips the write and says so in the log). Whenever the gate
finds an override on a head, it also makes sure the newest run of that name shows it: a
result that landed during a write, or one whose repair failed, is patched to the override on
the next gate run of any mode.

A `/test-e2e` run on a fork PR dispatches the base branch's workflow, so the run's own
`head_sha` is the base commit. The gate reads the PR and the tested commit from the run-name
instead, which the e2e workflow sets to `E2E for PR #<n> (<label>) at <sha>`.

Comments on the PR:

- `/qa-review override [<reason>]` from a member of an `override-teams` team (by
  default `loft-sh/eng-tech-leads`, `loft-sh/eng-staff-engineers` and `loft-sh/eng-qa`) or a login in `override-logins`
  completes both check-runs as success and records who overrode them and why. Team
  membership is read with `org-token`, a token with `read:org`; `GITHUB_TOKEN` cannot
  read it, and without the token only `override-logins` apply (the job says so). An
  override answers a panel verdict, so it lands only when the PR's current head
  carries a panel marker submitted before the comment. A head pushed after the
  comment, or one the panel has not graded yet, gets nothing: the job log says so
  and the lead comments again on what they see. When the panel never posted on that
  head (an outage), `/qa-review override <sha> [<reason>]` names the head instead; it
  lands only while that sha (7 to 40 hex characters) is still the PR head.
- `/qa-review human` from a repository member requests the QA team and leaves
  `qa-review` as action_required until a person decides.

After the e2e workflow finishes (`workflow_run`, mode `ci`), the action finds the
open PR for the run (from the event, or from the run's head commit when the run was
a `/test-e2e` dispatch). A cancelled run publishes nothing. A run whose head is no
longer the PR head is superseded and ignored. Otherwise it compares the PR base with
the run's own head (the commits the run tested), takes every `It(`, `Specify(` and table
`Entry(` the PR adds under an `e2e` directory with its line in the new file, downloads
the run's `ginkgo-report` artifact, and completes `qa-test-run`: failure when a new
spec is not in the report or did not pass, success otherwise. A spec is matched by
file and line (the report's `LeafNodeLocation`), never by text, so an existing spec
with the same text cannot stand in for a new one and a skipped namesake elsewhere
cannot fail it. The same location in two reports keeps the worst state. A PR that
adds no spec publishes nothing here (its `qa-test-run` is already green).

One PR can need several e2e runs before each new spec has run: `/test-e2e` runs with
different label filters, or a second e2e workflow. So the action reads the reports of
every finished run that tested the commit, from the workflows named in `e2e-workflows`
(the caller's `workflow_run` list; empty: only the workflow of the run that finished).
Runs are matched by workflow id, because a run's own name is its run-name.
A fork PR's `/test-e2e` runs are found on the base branch by their run-name, among
its newest 100 dispatch runs. A report
artifact is `ginkgo-report`, or `ginkgo-report-<job>` when matrix jobs each upload one;
an expired artifact is left out. Per spec the attempt that started last counts (the spec's `StartTime`; the
artifact's upload time when a report has none). A re-run keeps the run id and adds a
second artifact of the same name, so each artifact is read by its id. A spec a label filter left out
(`skipped`, `NumAttempts` 0) never replaces a real attempt, and a dry-run suite counts
for nothing.

A repo whose e2e workflows each test one source tree lists them in `report-trees`
(`artifact=path-prefix`; vcluster-pro: `ginkgo-report=` for Pro and
`oss-ginkgo-report=staging/github.com/loft-sh/vcluster/` for OSS). Each run grades the
specs of the tree it uploaded a report for and records every tree's result in the
check-run; the check stays `action_required` ("waiting for <artifact>") until every
tree that gained specs has reported, then turns success or failure. A run that
uploaded no report (a build failure) keeps the other trees' recorded results and asks
a person only for a tree with new specs that still has none. A compare the API may
have cut (300 files) gets `action_required`: re-run `/test-e2e` or a lead overrides.

Assigning the author (on `needs_human`) and requesting the QA team's review (on
`/qa-review human`) are best effort: when the token cannot do it, the job logs a
warning and stays green.

The action creates check-runs with the job's `GITHUB_TOKEN`; the caller grants
`checks: write` and `pull-requests: write` (`actions: read` too for `ci`). It
never posts review comments.

## Usage

```yaml
permissions:
  checks: write
  pull-requests: write
  contents: read

steps:
  - uses: loft-sh/github-actions/.github/actions/qa-review-gate@qa-review-gate/v1
    with:
      mode: ${{ github.event_name == 'pull_request_review' && 'review' || github.event_name == 'workflow_run' && 'ci' || github.event_name == 'pull_request' && 'bot' || 'comment' }}
      org-token: ${{ secrets.GH_ACCESS_TOKEN }}
```

The reusable workflow `.github/workflows/qa-review-gate.yaml` wraps this with the
checkout and the event filter.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |                                      DEFAULT                                       |                                                                                                                                     DESCRIPTION                                                                                                                                     |
|-----------------|--------|----------|------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     bot-prs     | string |  false   |              `"loft-bot:backport/,vcluster-qa-bot[bot]:flake-fixer/"`              |                                                                               Comma-separated login:branch-prefix pairs whose PRs pass <br>both check-runs on every head the <br>bot itself pushed.                                                                                 |
| caller-workflow | string |  false   |                                                                                    |                                           sweep mode without pr-number: the caller <br>workflow to start per PR, as <br>github.workflow_ref (owner/repo/.github/workflows/<file>@<ref>). Only this listing job <br>needs actions: write.                                            |
|   check-name    | string |  false   |                                   `"qa-review"`                                    |                                                                                                                           Name of the verdict check-run.                                                                                                                            |
|  e2e-workflows  | string |  false   |                                                                                    |                                     Comma-separated names of the e2e workflows <br>whose runs count for the test-run <br>check: the same list as the <br>caller's workflow_run trigger. Empty: only the <br>workflow of the run that finished.                                      |
|  github-token   | string |  false   |                              `"${{ github.token }}"`                               |                                        Token for gh. The calling job <br>must grant checks: write and pull-requests: <br>write; ci mode also needs actions: <br>read, the sweep listing (sweep mode without pr-number) actions: <br>write.                                          |
|      mode       | string |   true   |                                                                                    | "review" (pull_request_review event), "comment" (issue_comment event), "ci" (workflow_run event of the e2e workflow), <br>"bot" (pull_request event: trusted bot PRs and the QA-scope check) or "sweep" (workflow_dispatch: the QA-scope check for every open PR without a check).  |
|    org-token    | string |  false   |                                                                                    |                                                                              Token with read:org, used only to <br>read override-teams membership. GITHUB_TOKEN cannot; empty <br>disables the teams.                                                                               |
| override-logins | string |  false   |                                                                                    |                                                                                              Comma-separated logins allowed to run /qa-review <br>override, on top of override-teams.                                                                                               |
| override-teams  | string |  false   |       `"loft-sh/eng-tech-leads,loft-sh/eng-staff-engineers,loft-sh/eng-qa"`        |                                                                                Comma-separated org/slug teams whose members may <br>run /qa-review override. Membership is read <br>with org-token.                                                                                 |
|   panel-login   | string |  false   |                                    `"loft-bot"`                                    |                                                                                                     Login that posts the panel review. <br>Reviews by anyone else are ignored.                                                                                                      |
|    pr-number    | string |  false   |                                                                                    |                                                             sweep mode: grade this one PR <br>under its head queue. Empty: list <br>the open PRs lacking a check <br>and start one run of caller-workflow <br>per PR.                                                               |
|    qa-paths     | string |  false   | `"e2e*/**,staging/github.com/loft-sh/vcluster/e2e/**,.github/workflows/e2e*.yaml"` |                                                        Comma-separated glob patterns of the QA-owned <br>paths the review panel runs on. <br>A PR that touches none of <br>them passes both check-runs as out <br>of scope.                                                         |
|     qa-team     | string |  false   |                                 `"loft-sh/eng-qa"`                                 |                                                                                           org/slug of the team asked for <br>a review on /qa-review human. Empty <br>skips the request.                                                                                             |
|   queued-sha    | string |  false   |                                                                                    |                                         sweep mode with pr-number: the head <br>the calling job queued for (the reusable workflow resolves it before the queue). <br>The run grades the PR only <br>while it still sits on that <br>head.                                           |
|  report-trees   | string |  false   |                                 `"ginkgo-report="`                                 |                                     Comma-separated artifact=path-prefix pairs: which Ginkgo report <br>artifact covers which source tree. One <br>tree by default; vcluster-pro adds oss-ginkgo-report=staging/github.com/loft-sh/vcluster/.                                       |
| test-check-name | string |  false   |                                  `"qa-test-run"`                                   |                                                                                                 Name of the check-run that says <br>whether the new e2e specs ran <br>and passed.                                                                                                   |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->
No outputs.
<!-- AUTO-DOC-OUTPUT:END -->

## Testing

```bash
make test-qa-review-gate
```

Runs the pytest suite in `test/` against `src/gate.py`. No network: `apply` and
`collect_ci` are the only functions that call `gh`, and the tests never reach them.

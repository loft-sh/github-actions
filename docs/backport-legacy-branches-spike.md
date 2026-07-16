# Decision record: backporting monorepo PRs to pre-monorepo (≤ v0.36) lines

**Ticket:** DEVOPS-1051

This is a durable decision record for *why* the legacy backport path is shaped
the way it is. The concrete mechanics (routing, re-root, diff range, conflict
handling, allow-list) are documented in the living action READMEs
([`backport-legacy-split`](../.github/actions/backport-legacy-split/README.md),
[`backport-legacy-allowlist`](../.github/actions/backport-legacy-allowlist/README.md))
and the reusable [`backport.yaml`](../.github/workflows/backport.yaml); this file
only records the choices, not the implementation.

## Context

After the vCluster OSS → pro monorepo merge, `vcluster-pro` carries pro code at
the repo root and OSS code under `staging/github.com/loft-sh/vcluster/`. The
legacy release branches predate that layout (pro at root, OSS pulled via
`go.mod`; `loft-sh/vcluster` keeps OSS at root). A plain cherry-pick of a
monorepo commit onto a legacy branch is therefore wrong — for an OSS change it
recreates the `staging/` tree instead of patching the real paths.

## Decisions

1. **A new companion action, not an extension of `sorenlouv`.** sorenlouv does a
   single-repo, label-driven cherry-pick; it has no notion of path re-rooting,
   cross-repo targets, or splitting one commit into two PRs. Those four
   capabilities (route-by-path, re-root, cross-repo PR, mixed split) live in a
   dedicated `backport-legacy-split` action; sorenlouv stays for the monorepo-era
   cherry-pick.

2. **Era boundary is v0.37.** The split/re-root flow covers **≤ v0.36**; the
   monorepo era (mirror/FF propagation, plain cherry-pick) is **≥ v0.37**. Aligns
   with the release-era cutover (`loft-sh/github-actions` `d9da3aa`).

3. **Prerequisite for the monorepo merge, not blocked by it.** Merging without a
   working ≤ v0.36 backport path would strand the legacy lines (no security-fix
   delivery). The action is therefore built and validated against bats fixtures
   that reproduce the post-merge layout, and must be green before the merge lands.

4. **Route by changed path; mixed = two PRs in parallel.** pro-only → pro repo;
   OSS-only → re-rooted PR on `loft-sh/vcluster`; mixed → both, in parallel. No
   forced ordering, no "new OSS API" detection, and the action never cuts
   releases or tags. The pro half carries the PR's root `go.mod` diff as-is; the
   `loft-sh/vcluster` pin is human-reconciled during the sequenced merge (a
   conflicted PR is the expected mechanism).

5. **Allow-list at the shared-workflow layer.** The ≤ v0.36 / EOL guard lives in
   the reusable `backport.yaml` (not `targetBranchChoices`, which is
   interactive-only and never read by the label-driven CI flow), so it also caps
   the OSS side's external-contributor PR flow. In-support lines are derived
   dynamically from the vCluster lifecycle doc
   (`https://www.vcluster.com/docs/api/lifecycle/vcluster.json`), failing closed,
   with a hardcoded fallback only on a fetch/parse failure.

## Adjacent wiring preserved

Backport branches use the `backport/` prefix and the bot token so
`auto-approve-bot-prs`, `cleanup-backport-branches`, and `link-backport-prs`
keep working. (Cross-repo Linear linking for legacy PRs is a tracked follow-up.)

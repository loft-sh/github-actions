# fork-review-check

CLI behind the fork review check in [loft-sh/architecture `engineering-enablement/designs/fork-review-check.md`](https://github.com/loft-sh/architecture/blob/main/engineering-enablement/designs/fork-review-check.md). It verifies that every fork commit a product build consumes reached its loft-sh fork through a merged pull request approved by someone other than its author.

This is build step 1 of the design: the CLI, run read-only. The workflow and release receipt that make it a required check (step 4) build on it.

## Rules

For every fork commit S the build consumes, over the range from the trusted upstream base to S:

1. S is the approved final head, or the merge result, of a merged fork PR.
2. Every commit in the range must be an ancestor of an approved final head, that head itself, or a verified `web-flow` merge result of the merged PR. The approval must be after the last force push, by someone with write or higher permission on the fork who is neither the PR author nor the commit author. For a verified merge commit recorded as the PR's merge result with `web-flow` as committer, the code author is the PR author, so the approver may also be the merger. Rewritten commits from rebase merges that cannot be tied to the approved head fail closed.
3. With `-as-of`, every approval predates that time, normally the product release.
4. The check fails and names every commit that breaks a rule.

The upstream comes from the `fork-upstream` repository property, never from GitHub's fork parent. A fork without it fails. The base is:

| Pin | Base |
| --- | --- |
| Fork release tag (`v0.16.5.vcluster.1`, `v1.96.4-loft.3`) | The upstream tag before the suffix (`v0.16.5`), which must be an ancestor of S |
| Commit or Go pseudo-version | The merge base of S with the upstream default branch |

A tag without a fork suffix, a missing upstream tag, a base that is not an ancestor, or a range over 250 commits fails.

## Usage

```bash
export GITHUB_TOKEN=...   # read access to the forks; permission lookups need more, see below

# One fork ref: a tag or a full commit SHA.
go run . ref -repo loft-sh/kine -ref v0.16.5.vcluster.1

# Every loft-sh fork in the effective Go module graph of one or more modules.
GOPRIVATE=github.com/loft-sh/* go run . go -dir /path/to/vnode-internal
```

| Flag | Meaning |
| --- | --- |
| `-repo`, `-ref` | `ref` mode: the fork and the tag or commit to check |
| `-dir` | `go` mode: module directory, repeatable. S is the commit Go downloaded (`go mod download -json`, `Origin.Hash`), not today's tag |
| `-vendor-verifier` | `go` mode: trusted command that verifies the committed vendor tree in a temporary checkout. Required when a module has `vendor/` |
| `-upstream` | `fork=upstream[@branch]`, used only while a fork has no `fork-upstream` property. The missing property still fails; the override only keeps the per-commit evidence coming |
| `-as-of` | RFC 3339 time for rule 3 |
| `-receipt` | Write the JSON receipt to this path |
| `-advisory` | Report failures as warnings and exit 0 |

Exit codes: 0 pass or advisory, 1 a rule failed, 2 the check could not run.

`go` mode needs `GOPRIVATE=github.com/loft-sh/*` so Go fetches loft-sh modules from git and reports the origin commit; without an origin the module fails.

When a module contains `vendor/`, the downloaded module graph alone does not verify the code compiled from that directory. The check requires `-vendor-verifier`, for example `-vendor-verifier 'bash hack/verify-vendor.sh'` for a repository that provides that verifier. It also requires a clean Git checkout, including no ignored files in `vendor/`. The command runs in a temporary copy of the repository and must fail when the committed vendor tree differs from the generated tree. It is trusted code, not a sandbox: run this check only with a trusted command and repository. A missing or failing verifier fails the check. The consumer is responsible for selecting a verifier that preserves its vendor symlinks and checks all relevant files.

Workspace-level `vendor/` is not supported and fails closed. Use a module without workspace vendoring until a workspace verifier is supported.

## Receipt

The JSON receipt lists each input with its hash, each fork's `fork-upstream` value and source, the base, and every fork commit with its PR, approver, approval time and the approver's permission as read at check time. The permission endpoint returns current access only, so the receipt is the record and a later rerun can differ.

## Token

Reading PRs, reviews and compares on public forks works with any token. The approver permission lookup (`repos/{owner}/{repo}/collaborators/{user}/permission`) is the open question for the required workflow: `test-fork-review-check.yaml` runs the CLI against kine, tailscale and fuse with the workflow token to show whether that token can read it cross-repo.

## Not yet covered

Container images by digest, release binaries by sha256, source clones, and the fail-closed net for unknown fork references are step 4 of the design.

## Tests

```bash
make test-fork-review-check
```

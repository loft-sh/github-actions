# fork-review-check

CLI behind the fork review check in [loft-sh/architecture `engineering-enablement/designs/fork-review-check.md`](https://github.com/loft-sh/architecture/blob/main/engineering-enablement/designs/fork-review-check.md). It verifies that every fork commit a product build consumes reached its loft-sh fork through a merged pull request approved by someone other than its author.

It implements build steps 1 and 4 of the design: input resolution and the receipt a product release attaches.

## Rules

For every fork commit S the build consumes, over the range from the trusted upstream base to S:

1. S is the approved final head, or the merge result, of a merged fork PR.
2. Every commit in the range belongs to a merged fork PR approved at its final head, after its last force push, by someone with write or higher permission on the fork who is neither the PR author nor the commit author. For the merge commit GitHub writes when a PR merges, the code author is the PR author, so the approver may also be the merger.
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

# A digest-pinned fork image. -image and -signer-workflow are repeatable.
go run . image \
  -image ghcr.io/loft-sh/kine:v0.16.5.vcluster.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  -signer-workflow loft-sh/kine=.github/workflows/release.yml

# A fork release asset. -url and -sha256 are paired in flag order.
go run . binary \
  -url https://github.com/loft-sh/kine/releases/download/v0.16.5.vcluster.1/kine \
  -sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  -signer-workflow loft-sh/kine=.github/workflows/release.yml
```

| Flag | Meaning |
| --- | --- |
| `-repo`, `-ref` | `ref` mode: the fork and the tag or commit to check |
| `-dir` | `go` mode: module directory, repeatable. S is the commit Go downloaded (`go mod download -json`, `Origin.Hash`), not today's tag |
| `-image` | `image` mode: a `ghcr.io/<owner>/<name>:<fork-tag>@sha256:<digest>` image, repeatable |
| `-url`, `-sha256` | `binary` mode: a GitHub release asset URL and its 64-character SHA-256, paired and repeatable |
| `-signer-workflow` | `fork=.github/workflows/release.yml`, repeatable. Required for every image or binary fork |
| `-upstream` | `fork=upstream[@branch]`, used only while a fork has no `fork-upstream` property. The missing property still fails; the override only keeps the per-commit evidence coming |
| `-as-of` | RFC 3339 time for rule 3 |
| `-receipt` | Write the JSON receipt to this path |
| `-advisory` | Report failures as warnings and exit 0 |

Exit codes: 0 pass or advisory, 1 a rule failed, 2 the check could not run.

`go` mode needs `GOPRIVATE=github.com/loft-sh/*` so Go fetches loft-sh modules from git and reports the origin commit; without an origin the module fails.

## Scan mode

`scan` is the default mode of the composite action. It walks the build-input files below `-root` (`go.mod`, `go.work`, Dockerfiles, shell scripts, Makefiles, `.goreleaser` files and workflows) and resolves the fork commit S from what the build consumes. It skips `.git`, `vendor`, `node_modules` and `testdata`, and ignores whole-line comments.

| Form | Recognised shape | How S is resolved | Templated reference |
| --- | --- | --- | --- |
| Go | A `github.com/loft-sh/...` reference in `go.mod` or `go.work` | The effective Go module graph and `Origin.Hash` | Not applicable |
| Image | Dockerfile `FROM` or `COPY --from=` `ghcr.io/loft-sh/<fork>:<tag>@sha256:<digest>` | The fork release tag after provenance verification | Pass a digest-pinned `-image` for that fork |
| Source | `git clone -b` or `git clone --branch` from `github.com/loft-sh/<fork>`, or a workflow's `repository: loft-sh/<fork>` checkout | The tag or full SHA, as in `ref` mode | Pass `-source fork=tag-or-full-SHA` |
| Binary | `github.com/loft-sh/<fork>/releases/download/...` | Explicit URL and SHA-256 after checksum and provenance verification | Pass paired `-url` and `-sha256` |
| Link | Release tags, blobs, trees, pulls, issues, and commits | Ignored | Not applicable |

Any other fork reference fails, so a new build-input form cannot slip past the check. A templated reference (a variable with no default in the same file) passes only when the matching explicit flag names that fork. A `loft-sh` repository that is not a fork is ignored. An image whose name matches no repository (`ghcr.io/loft-sh/kine-fips`) is traced to the repository GitHub links its package to: a non-fork build repository such as `loft-sh/fips-builds` is ignored, a fork publishing under another name fails, and a package that cannot be read fails.

## Action inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED |           DEFAULT            |                                   DESCRIPTION                                    |
|------------------|--------|----------|------------------------------|----------------------------------------------------------------------------------|
|     advisory     | string |  false   |           `"true"`           |           Report rule failures without failing the <br>calling step.             |
|      as-of       | string |  false   |                              |             RFC 3339 release time that approvals <br>must predate.               |
|     binaries     | string |  false   |                              |        Newline-separated GitHub release asset URL and <br>SHA-256 pairs.         |
|       dirs       | string |  false   |                              |                     Newline-separated Go module directories.                     |
|   github-token   | string |  false   |   `"${{ github.token }}"`    | GitHub token used for read-only repository, <br>review, and permission lookups.  |
|      images      | string |  false   |                              |               Newline-separated digest-pinned ghcr.io fork images.               |
|       mode       | string |  false   |           `"scan"`           |         CLI mode. scan discovers supported build <br>inputs by default.          |
|     receipt      | string |  false   | `"fork-review-receipt.json"` |                       Path for the JSON evidence receipt.                        |
|       root       | string |  false   |            `"."`             |                          Root directory for scan mode.                           |
| signer-workflows | string |  false   |                              |    Newline-separated fork=.github/workflows/release.yml attestation mappings.    |
|     sources      | string |  false   |                              |            Newline-separated fork=tag-or-full-SHA source clone pins.             |
|    upstreams     | string |  false   |                              |      Newline-separated fork=upstream[@branch] temporary upstream mappings.       |

<!-- AUTO-DOC-INPUT:END -->

## Action outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

| OUTPUT  |  TYPE  |              DESCRIPTION               |
|---------|--------|----------------------------------------|
|  pass   | string | Whether the receipt passed every rule. |
| receipt | string |   Path to the JSON evidence receipt.   |

<!-- AUTO-DOC-OUTPUT:END -->

## Receipt

The JSON receipt lists each input with its hash, each fork's `fork-upstream` value and source, the base, and every fork commit with its PR, approver, approval time and the approver's permission as read at check time. The permission endpoint returns current access only, so the receipt is the record and a later rerun can differ.

## Token

Reading PRs, reviews and compares on public forks works with any token. `scan` also reads container package metadata, so the job needs `packages: read`. The approver permission lookup (`repos/{owner}/{repo}/collaborators/{user}/permission`) is the open question for the required workflow: `test-fork-review-check.yaml` runs the CLI against kine, tailscale and fuse with the workflow token to show whether that token can read it cross-repo.

## Product release caller

```yaml
- name: Check fork review evidence
  id: fork-review
  uses: loft-sh/github-actions/.github/actions/fork-review-check@fork-review-check/v1
  with:
    receipt: fork-review-receipt.json

- name: Attach fork review receipt
  env:
    GH_TOKEN: ${{ github.token }}
    TAG: ${{ github.ref_name }}
  run: gh release upload "$TAG" fork-review-receipt.json
```

The reusable `fork-review-check.yaml` workflow wraps the action for releases that also want the receipt as an Actions artifact. See [docs/workflows/fork-review-check.md](../../../docs/workflows/fork-review-check.md).

## Tests

```bash
make test-fork-review-check
```

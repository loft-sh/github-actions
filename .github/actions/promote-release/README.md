# Promote Release

Retags the moving docker tags (`:latest`, `:{major}`, `:{major}.{minor}`, and
any configured suffix variant such as `-fips`, `-amd64`, `-fips-arm64v8`) onto
the digest of an already published, already signed version tag — a
digest-preserving retag via `crane tag`, never a rebuild, so cosign signatures
(OCI referrers, digest-scoped) stay valid with no re-signing. Optionally also
promotes the caller's own release (`promote-self`) and a paired public release
in a companion repo (unsets `prerelease`, sets `latest`).

`version` is the **git tag** (`vX.Y.Z`), and the docker tags it reads and writes
are the **bare** form (`X.Y.Z`, `latest`, `9`, `9.9`) — goreleaser publishes image
tags from `{{ .Version }}`, which strips the leading `v`. Both ends of every
`crane tag` therefore live in the bare namespace, while the GitHub release edits
and the Homebrew download URLs keep the `v`. Callers whose images are tagged
*with* a leading `v` are not supported.

`crane tag` is used rather than `docker buildx imagetools create`: imagetools
is digest-preserving only when the source is already a multi-arch index. For a
bare single-platform manifest (a per-arch tag such as `:X.Y.Z-amd64`) it
wraps the manifest in a **new** index, changing its digest and orphaning the
digest-scoped cosign signature. `crane tag` re-points a tag at the exact same
manifest digest for both single-platform manifests and indexes, so it covers
the whole moving-tag matrix — including the per-arch tags — without breaking
signatures.

Wire this from `on: workflow_dispatch` on the repo that owns the moving tags,
taking the version to promote as an input. Do **not** wire it from
`on: release: types: [released]` when the caller publishes stable cuts with the
GitHub "None" label (`release.prerelease: auto` in goreleaser): `released` fires
at build time for such a cut, which would promote it unvetted. `release` events
are also resolved from the release's own tag ref, so they never fire for tags on
maintenance branches whose tree predates the workflow file. A `workflow_dispatch`
runs the copy from whichever ref it is dispatched on, so one dispatch covers
every release line with no backporting — the version to promote is an input, not
the ref. Note that this is a convention, not a guarantee: the dispatch form has a
branch picker and the API accepts any ref. Since a promotion moves public
pointers with a privileged token, the caller should assert the ref is the default
branch before the secret-bearing job runs.

Promotion runs must also be serialized within the caller repository. The
ordering guard reads the current Latest pointer before it writes any pointer;
without a shared concurrency group, two overlapping dispatches can both pass
against the same baseline and let the older release write last. The example
below uses a repository-wide `promote-release` group and does not cancel an
in-progress promotion.

Only acts on a stable `vX.Y.Z` version (no prerelease suffix); any other shape
is a no-op, since moving tags and "latest" promotion aren't meaningful for
`-rc`/`-alpha`/`-next` cuts.

**Backport-safe:** before advancing `:latest`/`:{major}` (or `--latest` on
`oss-repo` / the caller's own release), the action checks whether `version` is
newer than the release currently flagged **Latest** on the caller's own repo
(`GITHUB_REPOSITORY`, set automatically by Actions) / on `oss-repo`. That Latest
pointer is the baseline, *not* "newest non-prerelease": under
`release.prerelease: auto` a published-but-un-promoted stable cut is already
non-prerelease, so the Latest flag is the only durable record of what `:latest`
actually tracks — reading the prerelease flag instead would strand `:latest`
behind any newer un-promoted cut. Promoting an older line's patch after a newer
stable is already `:latest` skips `:latest`/`:{major}`, so they never move
backwards. Re-promoting the release that is already Latest is allowed, so a
partially failed promotion can simply be re-run.

The paired `oss-repo` Latest pointer and Homebrew formula advance only when
`version` passes **both** the caller-repository gate and the `oss-repo` gate.
The caller pointer is the authoritative baseline for the coordinated Docker
release, so a stale paired-repository pointer after an earlier advisory failure
cannot reclassify a caller backport as a newest release and move public pointers
backwards.

If **no** release carries the Latest flag, the baseline falls back to the newest
stable-shaped tag rather than to "advance". The flag is clearable — re-running a
release build re-asserts `make_latest: false` on the tag that holds it — so an
absent pointer must not be read as "nothing has ever been promoted"; that would
let a dispatch for an older line drag `:latest` backwards. A genuinely empty
release list still advances, which is the real first-ever promotion.

Because GitHub lets a human flag *any* release Latest, that baseline can be a
pre-release tag, so the gates compare under semver precedence rather than
`sort -V` alone — `sort -V` ranks `v0.36.1-rc.1` above `v0.36.1`, which would
read an rc holding the pointer as newer than the stable release it precedes and
withhold that release's whole promotion on a green run. A pre-release that is
genuinely ahead of `version` still blocks it.

`:{major}.{minor}` is scoped to its own line and gets its own check: it advances
only when `version` is the newest stable-shaped tag *within that
`{major}.{minor}` line* (GitHub has no per-line equivalent of the Latest
pointer), so an out-of-order same-line promotion (e.g. promoting `v9.9.5` after
`v9.9.6` already moved `:9.9`) can't regress it either. That check keys on tag
shape alone and deliberately ignores the pre-release flag, which is mutable: a
stable-shaped tag can carry it (every cut did under the legacy
`release.prerelease: true` config, and re-running such a build re-flags an
already-promoted tag), and filtering on it would drop the newer sibling from the
comparison and permit exactly the regression the check exists to stop.

A failure to even list releases fails the run closed rather than risk a silent
downgrade.

Optionally also promotes a Homebrew tap (`homebrew-tap-repo` +
`homebrew-formula-paths`) — a metadata patch, not a rebuild. A formula's
per-platform `sha256` values are exactly what's already in `oss-repo`'s
`version` release `checksums.txt` (already published, already cosign-signed),
so nothing is re-hashed; only the `version` line and each `url`/`sha256` pair
are rewritten in place, with everything else in the formula (deps, install
blocks, `test do`) preserved byte-for-byte. Same backport rule applies, but
as an all-or-nothing skip — a formula has no line-scoped equivalent to
`:{major}.{minor}`.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|         INPUT          |  TYPE  | REQUIRED |  DEFAULT  |                                                                                                                                             DESCRIPTION                                                                                                                                              |
|------------------------|--------|----------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    docker-username     | string |   true   |           |                                                                                Username paired with github-token for the <br>GHCR login (GHCR checks the token, but docker/login-action requires a username value).                                                                                  |
|        dry-run         | string |  false   | `"false"` |                   Fail-closed: a real promotion runs only <br>on an exact "false" (the default, so a plain dispatch still promotes for real). Any <br>other value ("true", a typo, etc.) is a dry-run, <br>which writes nothing but still reads <br>the registry; see the README.                    |
|      github-token      | string |   true   |           |                                                                Token with GHCR write:packages; contents:write on <br>the caller repo when promote-self is <br>true; and contents:write on oss-repo and <br>homebrew-tap-repo if set.                                                                 |
| homebrew-formula-paths | string |  false   |  `"[]"`   |                                                                          JSON array of formula file paths <br>within homebrew-tap-repo to update, e.g. ["Formula/vcluster.rb"]. <br>Required if homebrew-tap-repo is set.                                                                            |
|   homebrew-tap-repo    | string |  false   |           |                                                              owner/repo of a Homebrew tap to <br>promote (e.g. loft-sh/homebrew-tap). Requires oss-repo to be <br>set, since checksums come from its <br>release. Leave empty to skip.                                                               |
|         images         | string |   true   |           |             JSON array of image entries to <br>retag, each `{"image": "ghcr.io/loft-sh/x", "suffix": ""}` (suffix optional, default <br>""). Docker tags are the bare <br>version, without the `v` that `version` <br>carries; see the README for the <br>full retag/suffix semantics.               |
|        oss-repo        | string |  false   |           |                                                                                  owner/repo whose matching <version> release should <br>also be promoted (prerelease unset, latest set). Leave empty <br>to skip.                                                                                    |
|      promote-self      | string |  false   | `"false"` | Set to "true" to also promote <br>the CALLER repo's own <version> release <br>(unset pre-release, set Latest, gated by the same backport check as :latest). Off by default; only an <br>exact "true" enables it. See the <br>README promote-self section for token scope <br>and failure semantics.  |
|        version         | string |   true   |           |                                                                                                                               The promoted release tag, e.g. v0.37.1.                                                                                                                                |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|        OUTPUT        |  TYPE  |                                                                                                                                                                     DESCRIPTION                                                                                                                                                                     |
|----------------------|--------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| promote-self-enabled | string |                                                                                                                         Whether the manifest forwarded an exact <br>"true" promote-self value to the promotion <br>script.                                                                                                                          |
|  unresolved-sources  | string | How many configured source manifests could <br>not be resolved at the bare <br>version tag. Always 0 on a <br>successful real promotion, since it aborts <br>otherwise; on a dry-run this is <br>the only machine-readable signal that the <br>rehearsed plan would not execute, so <br>gate or alert on it rather <br>than on the job conclusion.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Stable version to promote, e.g. v0.37.1"
        type: string
        required: true

# The ordering gate is a read-then-write operation. Serialize every promotion
# in this repository so two dispatches cannot both pass against the same Latest
# pointer and let the older run write last.
concurrency:
  group: promote-release
  cancel-in-progress: false

jobs:
  promote:
    # workflow_dispatch can target any ref. Keep the secret-bearing promotion
    # on the repository default branch's reviewed workflow definition.
    if: github.ref == format('refs/heads/{0}', github.event.repository.default_branch)
    runs-on: ubuntu-latest
    permissions:
      packages: write
      contents: read
    steps:
      - name: Promote release
        uses: loft-sh/github-actions/.github/actions/promote-release@promote-release/v1
        with:
          version: ${{ inputs.version }}
          promote-self: "true"
          oss-repo: loft-sh/vcluster
          github-token: ${{ secrets.GH_ACCESS_TOKEN }}
          docker-username: ${{ secrets.DOCKER_USERNAME }}
          images: |
            [
              {"image": "ghcr.io/loft-sh/vcluster-pro"},
              {"image": "ghcr.io/loft-sh/vcluster-pro", "suffix": "-fips"},
              {"image": "ghcr.io/loft-sh/vcluster-pro-fips"},
              {"image": "ghcr.io/loft-sh/vcluster-oss"},
              {"image": "ghcr.io/loft-sh/vcluster-cli"}
            ]
          homebrew-tap-repo: loft-sh/homebrew-tap
          homebrew-formula-paths: |
            ["Formula/vcluster.rb", "Formula/vcluster-experimental.rb"]
```

Use the documented PAT/App token for `github-token`; do not substitute the
workflow `GITHUB_TOKEN` when `oss-repo` or `homebrew-tap-repo` is configured.
The workflow token cannot write those other repositories, leaving the paired
release or formula un-promoted.

### Why this needs a build-time gating change too

This action only *retags* — the moving tags must not already exist from the
build. The caller's `.goreleaser.yaml` (or equivalent) must publish only the
immutable `:<version>` tag at build time and never the moving tags.

The GitHub Release itself should be published with the "None" label, i.e.
`release.prerelease: auto` (a stable `vX.Y.Z` is not flagged pre-release, every
suffixed tag is) plus `make_latest: false` (nothing is Latest at build time).
The release is then listed and downloadable at its exact tag, while every
*pointer* a consumer follows — `releases/latest`, the moving docker tags, a
stable Homebrew formula — stays behind this action.

Note that goreleaser re-asserts both flags on every run: a re-run of the build
against an already-promoted tag will clear its Latest flag (`make_latest: false`
is sent again on publish). Re-run this action afterwards to restore it; it is
idempotent.

A caller still on `prerelease: true` also works: `--prerelease=false` is part of
what `promote-self`/`oss-repo` apply, so a legacy tag built under the old config
promotes through the same dispatch.

### GHCR login

`crane tag` needs to push to GHCR. `action.yml` includes a `docker/login-action`
step using `docker-username` + `github-token` (GHCR checks the token;
`docker/login-action` still requires a username value); crane reads the docker
config that step writes, so no separate crane login is needed. `action.yml` also
installs crane (`imjasonh/setup-crane`), so callers don't need to install it
themselves.

The install runs **before** the login, and the order is load-bearing.
`setup-crane` finishes with its own `crane auth login ghcr.io` hardcoded to the
workflow's `github.token`, writing the same `~/.docker/config.json` entry as
`docker/login-action` — last writer wins. Installed after the login, that
replaces `github-token` with the workflow token, which can still write every
package owned by the caller repo and is denied on every package owned by another
one (`DENIED: permission_denied: write_package`). A promotion spanning both then
dies partway through with one image family's moving tags already retagged. The
smoke job pins the order by reading the stored username back: `docker-username`
means the login won, `dummy` means `setup-crane` did.

Both steps run for a `dry-run` as well, because the rehearsal resolves every
source manifest (see [Source-manifest pre-flight](#source-manifest-pre-flight))
and a package that is not publicly readable fails crane's anonymous token
exchange outright, so without the credential the lookup cannot tell you anything.
Neither step writes to the registry — `crane tag` is the only mutation and it
stays behind the dry-run guard.

The rehearsal's login is a separate step carrying a literal
`continue-on-error: true`, so a bad credential or a GHCR hiccup degrades into the
pre-flight's `could not be inspected` wording instead of killing the preview. It
has to be a separate step rather than one step with an expression:
`continue-on-error: ${{ inputs.… }}` on a composite step is evaluated in the
composite's own context, where it resolves empty and halts the run with
`Unexpected value ''` ([actions/runner#2418][coe], still open). Literal booleans
are unaffected.

[coe]: https://github.com/actions/runner/issues/2418

### promote-self

Off by default. Set it to `"true"` when the caller's own GitHub Release needs
flipping as part of the promotion — which is the case whenever stable cuts are
published with the "None" label, since nothing else ever promotes them. The
release is edited to `--prerelease=false --latest`, with `--latest` withheld on a
backport promotion (same gate as `:latest`). Only an exact `"true"` enables it.

The `github-token` must also have `contents: write` on the **caller's own**
repository (`GITHUB_REPOSITORY`) when this option is enabled, in addition to
any permissions needed for `oss-repo` and `homebrew-tap-repo`. Without it the
required `gh release edit` cannot establish the caller's Latest pointer and an
advancing promotion fails before any moving tags are changed.

Adopting this `promote-self` flow and the GitHub `None` label is one coordinated
notification change: the paired `notify-release` caller must also set
`needs_promotion: true`. Without that opt-in the release banner has no promotion
reminder, so the Release Captain has no signal that this dispatch is still due.

This edit runs **before** the docker retags, not after, and on an advancing
promotion any failure to complete it — the release being unreadable, or the edit
itself failing — is **fatal**, aborting before anything is retagged. The reason
is that this one edit writes the same Latest pointer the backport gate reads back
as its baseline on every later run. Retagging first would mean a failure here
leaves the pointer *behind* `:latest`, and the next dispatch for an older line
would pass that stale gate and move `:latest` backwards. Doing it first inverts
the failure mode: a later `crane` failure leaves the pointer *ahead*, which can
only refuse a subsequent older promotion, never permit a regression. Re-promoting
the same version is always allowed, so a plain re-run recovers.

On a backport promotion none of this applies — the edit is `--prerelease=false`
only, which moves no pointer and cannot stale a baseline — so a missing release
or a failed edit stays a warning and the line tag still advances. A `dry-run` is
likewise never aborted by an unreadable release: a rehearsal may run before the
release exists, so it warns and prints the planned edit instead.

### images

One entry per moving-tag family, each `{"image": "...", "suffix": ""}` with the
suffix optional. For every entry the source `<image>:X.Y.Z<suffix>` is copied to

- `<image>:latest<suffix>`
- `<image>:<major><suffix>`
- `<image>:<major>.<minor><suffix>`

so the suffix applies to the source *and* to every destination. That is also how
per-arch moving tags are promoted: an entry with suffix `-amd64` retags
`<image>:X.Y.Z-amd64` — a bare single-platform manifest — onto
`<image>:latest-amd64` and friends, digest preserved, so its cosign signature
stays valid. Keep the list in step with whatever the build publishes; a family
listed here but not built for this version fails the pre-flight below, and one
built but not listed here is simply never promoted.

Which of the three destinations actually move depends on the backport gates
above: `:latest`/`:{major}` only when `version` is at or ahead of the caller's
Latest pointer, `:{major}.{minor}` only when it is newest within its own line.

### Source-manifest pre-flight

Before anything is written, every configured entry's source manifest is resolved
at `<image>:X.Y.Z<suffix>`. A suffix variant that was never built for this
version, or a wrong tag namespace, therefore fails before the first retag rather
than part-way through one.

It runs under `dry-run` too, and only the verdict differs: a real promotion
aborts, a rehearsal warns and keeps printing the plan. Skipping the lookup in a
rehearsal made it answer "yes" for plans that could not execute, which is the one
question a rehearsal exists to answer. It is non-fatal there for the same
pre-publish reason as the release lookup above — rehearsing a cut whose images
are not published yet is allowed — but it is not *skipped*.

"Unresolved" covers two different facts and the wording says which, because
reporting a denial as a missing image sends an operator to re-cut something that
is already published:

| Wording | Means | Recognised by |
|---|---|---|
| `does not exist` | the tag was never pushed — usually a tag-namespace or build-matrix mismatch | `unexpected status code 404` on a `/manifests/` URL, or a registry `MANIFEST_UNKNOWN`/`NAME_UNKNOWN` |
| `could not be inspected (<error>)` | the registry did not answer — a refused token exchange, a rate limit, DNS | anything else, with the raw error attached |

The split is matched against what crane actually prints (verified live against
ghcr.io on the pinned v0.20.2): crane renders the HTTP status itself and never
surfaces the registry's `MANIFEST_UNKNOWN`, and a package the run cannot read
fails at the *token exchange* rather than reaching a manifest 404 — which is what
keeps a failed login out of the absence bucket. The match is deliberately the
phrase `unexpected status code 404` on a `/manifests/` URL, not a bare `404`
anywhere in the text: a host carrying those digits, or a 404 from the token
endpoint or a proxy in front of it, stays indeterminate. Only the manifest lookup
can prove a tag missing.

If crane itself is missing the run fails outright: that is not evidence about any
manifest, and treating it as absence would report every source as unpublished.
When the non-fatal rehearsal login did not succeed, that is stated before the
per-entry list, so a bad credential is named rather than inferred.

Every entry is reported before the decision — the loop is read-only, so the abort
simply moves after it, and one dispatch surfaces the whole list instead of one
image per re-dispatch. The aggregate names the split (`N not found, M
uninspectable`) and advises per class, so a run where one image is genuinely
missing and forty are unreadable does not steer you at the tag form. The verdict,
with the affected refs, also goes to `$GITHUB_STEP_SUMMARY` (capped at 20 plus a
count): a rehearsal stays green, and a long annotation list is easy to mistake
for a clean pass. Plan lines whose source did not resolve are marked
`WOULD FAIL`, so the printed plan carries its own verdict.

All of that still needs a human to open the run. The `unresolved-sources` output
is the one channel a *caller* can read: it is the count of sources that did not
resolve, `0` on a clean run and on the non-stable no-op, and it is written before
a real run aborts. Since a rehearsal is green either way, gate or alert on that
output rather than on the job conclusion.

### oss-repo

If set, and a release matching `version` exists on `oss-repo`, it is edited
to `--prerelease=false`; `--latest` is added only when both the caller and
`oss-repo` ordering gates allow it. If no matching release exists, this step is
skipped with a warning — it does not fail the docker retagging. An edit failure
also remains advisory, but Homebrew promotion is skipped so the formula cannot
advance ahead of the paired release.

### homebrew-tap-repo

Requires `oss-repo` to be set — the formula's checksums come from
`oss-repo`'s `version` release `checksums.txt`, matched to each formula's
existing `url` lines by artifact filename (e.g. `vcluster-darwin-amd64`).
`github-token` needs `contents: write` on `homebrew-tap-repo` (via the
GitHub Contents API, not a git clone/push). Each formula's `version` line and
matched `url`/`sha256` pairs are rewritten; an artifact with no matching
checksum keeps its previous `sha256` and logs a warning rather than failing.
Failures here (checksums download, contents fetch, or the update itself) warn
and skip — they never fail the run, since the docker retags (and `oss-repo`
promotion, if configured) have already succeeded by this point.

## Testing

```bash
make test-promote-release
```

Runs the bats suite in `test/` against `src/action.sh` with stubbed `crane`
and `gh` on `PATH`.

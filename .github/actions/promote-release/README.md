# Promote Release

Retags the moving docker tags (`:latest`, `:{major}`, `:{major}.{minor}`, and
any configured suffix variant such as `-fips`, `-amd64`, `-fips-arm64v8`) onto
the digest of an already published, already signed version tag — a
digest-preserving retag via `crane tag`, never a rebuild, so cosign signatures
(OCI referrers, digest-scoped) stay valid with no re-signing. Optionally also
promotes the caller's own release (`promote-self`) and a paired public release
in a companion repo (unsets `prerelease`, sets `latest`).

`crane tag` is used rather than `docker buildx imagetools create`: imagetools
is digest-preserving only when the source is already a multi-arch index. For a
bare single-platform manifest (a per-arch tag such as `:{version}-amd64`) it
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
maintenance branches whose tree predates the workflow file — a
`workflow_dispatch` always runs the default branch's copy and therefore covers
every release line with no backporting.

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
partially failed promotion can simply be re-run. `:{major}.{minor}` is scoped to
its own line and gets its own check: it advances only when `version` is the
newest stable *within that `{major}.{minor}` line* (GitHub has no per-line
equivalent of the Latest pointer), so an out-of-order same-line promotion (e.g.
promoting `v9.9.5` after `v9.9.6` already moved `:9.9`) can't regress it either.
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

|         INPUT          |  TYPE  | REQUIRED |  DEFAULT  |                                                                                                                                                                                                                                                                              DESCRIPTION                                                                                                                                                                                                                                                                               |
|------------------------|--------|----------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    docker-username     | string |   true   |           |                                                                                                                                                                                                                 Username paired with github-token for the <br>GHCR login (GHCR checks the token, but docker/login-action requires a username value).                                                                                                                                                                                                                   |
|        dry-run         | string |  false   | `"false"` |                                                                                                                                                                Fail-closed: a real promotion runs only <br>on an exact "false" (the default, so a plain dispatch still promotes for real). Any <br>other value ("true", a typo, etc.) is a dry-run <br>that only prints the planned retags/promotion.                                                                                                                                                                  |
|      github-token      | string |   true   |           |                                                                                                                                                                                                                                   Token with GHCR write:packages, and contents:write <br>on oss-repo and homebrew-tap-repo if set.                                                                                                                                                                                                                                     |
| homebrew-formula-paths | string |  false   |  `"[]"`   |                                                                                                                                                                                                           JSON array of formula file paths <br>within homebrew-tap-repo to update, e.g. ["Formula/vcluster.rb"]. <br>Required if homebrew-tap-repo is set.                                                                                                                                                                                                             |
|   homebrew-tap-repo    | string |  false   |           |                                                                                                                                                                                               owner/repo of a Homebrew tap to <br>promote (e.g. loft-sh/homebrew-tap). Requires oss-repo to be <br>set, since checksums come from its <br>release. Leave empty to skip.                                                                                                                                                                                                |
|         images         | string |   true   |           | JSON array of image entries to <br>retag, each `{"image": "ghcr.io/loft-sh/x", "suffix": ""}` (suffix optional, default <br>""). For each entry, copies `<image>:<version><suffix>` <br>to `<image>:latest<suffix>`, `<image>:<major><suffix>`, and `<image>:<major>.<minor><suffix>`. The <br>suffix is also how per-arch moving <br>tags are promoted: an entry with <br>suffix `-amd64` retags `<image>:<version>-amd64` (a bare single-platform manifest) to <br>`<image>:latest-amd64` etc. crane preserves its digest, <br>so its cosign signature stays valid.  |
|        oss-repo        | string |  false   |           |                                                                                                                                                                                                                   owner/repo whose matching <version> release should <br>also be promoted (prerelease unset, latest set). Leave empty <br>to skip.                                                                                                                                                                                                                     |
|      promote-self      | string |  false   | `"false"` |                                                                                                                                Set to "true" to also promote <br>the CALLER repo's own <version> release <br>(unset pre-release, set Latest). Required when the caller publishes <br>stable cuts with the GitHub "None" <br>label, since nothing else ever flips <br>them. Latest is gated by the <br>same backport check as :latest.                                                                                                                                  |
|        version         | string |   true   |           |                                                                                                                                                                                                                                                                The promoted release tag, e.g. v0.37.1.                                                                                                                                                                                                                                                                 |

<!-- AUTO-DOC-INPUT:END -->

## Usage

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Stable version to promote, e.g. v0.37.1"
        type: string
        required: true

jobs:
  promote:
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
config that step writes, so no separate crane login is needed. The login is
skipped automatically when `dry-run: true`. `action.yml` also installs crane
(`imjasonh/setup-crane`), so callers don't need to install it themselves.

### promote-self

Off by default. Set it to `"true"` when the caller's own GitHub Release needs
flipping as part of the promotion — which is the case whenever stable cuts are
published with the "None" label, since nothing else ever promotes them. The
release is edited to `--prerelease=false --latest`, with `--latest` withheld on a
backport promotion (same gate as `:latest`). A missing release warns and skips.
Only an exact `"true"` enables it.

### oss-repo

If set, and a release matching `version` exists on `oss-repo`, it is edited
to `--prerelease=false --latest`. If no matching release exists, this step is
skipped with a warning — it does not fail the docker retagging.

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

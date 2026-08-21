# Setup semstat Action

Installs [`semstat`](https://github.com/loft-sh/semstat), the semver CLI this
repository's release actions answer semver questions with, from a pinned release.
Resolves the runner's os and arch, downloads the archive and the release
`checksums.txt`, verifies the one line that covers the archive, unpacks it, and
proves the result runs by comparing `semstat version` against the tag that was
asked for.

The binary lands on `PATH`, so the actions that call semstat from inside a shell
function or a `while read` loop can just run `semstat`. The absolute path is an
output as well, for a caller that would rather name the binary than depend on
`PATH` ordering.

One pin lives here rather than one per action, so there is one place to bump and
one release under review rather than five that can drift apart. An action in this
repository runs the installer out of the same checkout and so is never behind it;
a consumer in another repository pins this action by SHA and gets a bump when that
pin moves.

## Runner requirements

A Linux or macOS runner with `curl`, `tar` and `sha256sum` (or `shasum`) on it,
and egress to `github.com/loft-sh/semstat/releases/download` **and**
`objects.githubusercontent.com`, which release-asset downloads redirect to. A
proxy allowlist naming only `github.com` fails the download.

`verify-signature: true` needs two more hosts. `cosign` is downloaded from the
`github.com/sigstore/cosign` releases, by this action rather than by the runner
image, and cosign then checks the transparency log against a trusted root it
fetches from `tuf-repo-cdn.sigstore.dev`. An egress-restricted runner has to
allow both or the step fails inside cosign.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED |  DEFAULT  |                                                                                                                                                              DESCRIPTION                                                                                                                                                              |
|------------------|--------|----------|-----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| verify-signature | string |  false   | `"false"` | Verify `checksums.txt` against its cosign bundle <br>before trusting it, proving the release <br>came from semstat's own release workflow <br>at this exact tag rather than <br>only that the download arrived intact. <br>Costs a cosign install on the <br>job, so it is off by <br>default; turn it on for jobs <br>that publish.  |
|     version      | string |  false   |           |                                               Release of [loft-sh/semstat](https://github.com/loft-sh/semstat) to install. Empty <br>installs the release pinned in `src/install-semstat.sh`, <br>which is where Renovate bumps it <br>and where every entry point reads <br>it from.                                                 |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

| OUTPUT |  TYPE  |                                                                         DESCRIPTION                                                                          |
|--------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
|  path  | string | Absolute path to the verified semstat <br>binary. The directory holding it is <br>also on PATH for later steps, <br>so a caller can just run <br>`semstat`.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

### From a workflow, or from an action in another repository

```yaml
- name: Install semstat
  id: semstat
  uses: loft-sh/github-actions/.github/actions/setup-semstat@<sha> # setup-semstat/v1

- name: Pick the newest tag
  shell: bash
  run: |
    newest=""
    while read -r tag; do
      semstat validate "$tag" 2>/dev/null || continue
      if [ -z "$newest" ] || semstat gt "$tag" "$newest"; then
        newest="$tag"
      fi
    done < <(git tag -l 'v*')
    echo "$newest"
```

Pin the full commit SHA with the tag in a trailing comment, the way `cve-scan`
and `govulncheck` reference `ci-test-notify`. A fix to the installer reaches such
a consumer only when its SHA is bumped, so releasing this action means advancing
`setup-semstat/v1` and then moving each cross-repo pin onto the new commit.

### From another action in this repository

Run the script instead of pinning the action. Copy this whole shape rather than
the one-line `run:` it reduces to: the `env:` block and the existence check are
both load-bearing, for the reasons below.

```yaml
- name: Check whether this job still needs cosign
  id: cosign
  if: inputs.verify-signature == 'true'
  shell: bash
  env:
    COSIGN_MARKER: ${{ runner.temp }}/.setup-semstat-cosign-installed
  run: |
    install=true
    if [ -f "$COSIGN_MARKER" ]; then
      install=false
    elif ! : >"$COSIGN_MARKER"; then
      echo "::error::could not record that this job installs cosign at ${COSIGN_MARKER}"
      exit 1
    fi
    if ! echo "install=${install}" >>"$GITHUB_OUTPUT"; then
      echo "::error::could not write whether this job needs cosign to GITHUB_OUTPUT"
      exit 1
    fi

- name: Install cosign
  if: inputs.verify-signature == 'true' && steps.cosign.outputs.install == 'true'
  uses: sigstore/cosign-installer@<sha> # v4.1.2

- name: Install semstat
  id: install
  shell: bash
  env:
    SEMSTAT_VERIFY_SIGNATURE: ${{ inputs.verify-signature }}
    SEMSTAT_VERSION: ""
    SEMSTAT_BASE_URL: ""
    SEMSTAT_SKIP_PATH: ""
    INSTALLER: ${{ github.action_path }}/../setup-semstat/src/install-semstat.sh
  run: |
    if [ ! -x "$INSTALLER" ]; then
      echo "::error::${INSTALLER} is missing or not executable; this action runs the installer that ships with the sibling setup-semstat action, so a sparse checkout has to take .github/actions/setup-semstat as well"
      exit 1
    fi
    "$INSTALLER"
```

Neither form of `uses:` works for a sibling in the same repository. A relative
`uses: ./...` resolves against the caller's workspace rather than against this
repository, so it finds nothing once the action is consumed from `vcluster-pro` or
`loft-enterprise`. A full `loft-sh/github-actions/...@<sha>` pin does resolve, but
a sibling can only be pinned at a commit that predates the change needing it, and
it then keeps running that commit while fixes to the installer land beside it —
the pin drift from DEVOPS-1126 and DEVOPS-923, silent because the action still
works. `github.action_path` is inside a full checkout of this repository, so the
two ship from one commit and cannot drift apart. `semver-validation` is the
worked example.

Bind every variable the script reads in that same `env:`, including the ones the
calling action does not expose: a composite step inherits the job's environment
and step env is what wins, so a name left unbound lets a workflow-level `env:` or
an earlier `GITHUB_ENV` write repoint the download root, the release that gets
installed, or whether semstat lands on `PATH` at all. All four are optional to the
script and every one of them is worth binding.

Check the script is there before running it. `github.action_path` reaches outside
the calling action's own directory, and this repository's workflows do sparse
single-action checkouts, so a caller that took only its own action directory
otherwise dies on bash's bare `No such file or directory` with no `::error::` line
naming what the checkout has to include.

Verifying also needs `cosign` on `PATH`, which is a `uses:` step and so cannot be
lent out by a script. That is why the marker step above sits in front of it:
cosign-installer re-downloads its bootstrap binary on every call, while every
semstat install after the first is a cache hit that never reaches cosign, so an
action invoked several times in one job would pay for a bootstrap it does not use.
The marker lives under `RUNNER_TEMP`, private to the job, which is what makes the
skip reuse an install this job already did rather than adopt whatever `cosign` a
runner image happened to ship. Keep the marker path byte-identical to the one in
`setup-semstat/action.yml` and `semver-validation/action.yml`, since that shared
path is how a job mixing these actions installs cosign only once. Drop the step
only if the calling action can run at most once per job.

Set `SEMSTAT_SKIP_PATH: "true"` where the calling action names the binary through
the step output and never runs a bare `semstat`, because the append is then a
change to the caller's job with nothing reading it. `semver-validation` does
exactly this.

The step output is `semstat` rather than this action's `path` output, because the
script writes it directly: `${{ steps.install.outputs.semstat }}`.

### Naming the binary instead of relying on PATH

```yaml
- name: Install semstat
  id: semstat
  uses: loft-sh/github-actions/.github/actions/setup-semstat@<sha> # setup-semstat/v1

- name: Order two versions
  shell: bash
  env:
    SEMSTAT_BIN: ${{ steps.semstat.outputs.path }}
  run: "$SEMSTAT_BIN" gt "$CANDIDATE" "$CURRENT"
```

### Verifying who produced the release

```yaml
- name: Install semstat
  uses: loft-sh/github-actions/.github/actions/setup-semstat@<sha> # setup-semstat/v1
  with:
    verify-signature: true
```

`checksums.txt` on its own proves the download arrived intact and that the asset
name resolved inside the release that was asked for. It does not prove who
produced that release, because the manifest comes from the same place as the
archive. With `verify-signature: true` the action installs `cosign` and verifies
`checksums.txt` against its Sigstore bundle before reading it, at the exact
identity:

```
https://github.com/loft-sh/semstat/.github/workflows/release.yaml@refs/tags/<version>
```

The tag is part of the identity, not a wildcard, so a bundle signed by the same
workflow on any other ref does not pass. It is off by default because it costs a
cosign install on every job that touches a release path, and because signature
verification of a first-party binary out of a first-party release is largely
ceremony. Turn it on for jobs that publish.

## Reusing an install across steps

The unpack directory is keyed by release and platform under `RUNNER_TEMP`, so a
job that installs semstat in several steps downloads the release once. A cached
install is reused only if the binary still runs, still agrees about its version,
and was verified as strictly as the step asks: a step with
`verify-signature: true` re-installs over whatever an earlier unverified step
left behind rather than trusting it.

The runner *prepends* `GITHUB_PATH` entries, so where two steps install different
semstat releases into the same job, a later bare `semstat` resolves to whichever
installed last. Anything that cares which release it is talking to should name the
`path` output instead of relying on that order; an in-repository caller that only
ever names the output can set `SEMSTAT_SKIP_PATH` and leave the job's `PATH` out
of it altogether.

## Upgrading the pinned release

`DEFAULT_VERSION` in `src/install-semstat.sh` is the pin, carrying the
`# renovate: datasource=github-releases depName=loft-sh/semstat` comment that a
`customManager` in `renovate.json` reads. It lives in the script rather than in
`action.yml` because both entry points reach the script, and the `version` input
only overrides it; two defaults would be two pins that can disagree.

Renovate opens one bump, and no consumer carries a pin of its own. An action in
this repository gets it in the same commit. A cross-repo consumer pins this action
by SHA, so for it the bump lands here first and ships when its pin moves — two
steps, the same way any change to this action ships.

The action refuses a binary that reports a different version than the one asked
for, so a mismatched or truncated download fails the step rather than answering
wrongly.

## Development

```bash
make test-setup-semstat   # bats suite
make lint                 # actionlint + zizmor
make generate-docs        # refresh the tables above from action.yml
```

The suite serves a release from disk through a stubbed `curl` and a stubbed
`cosign`, so the download, the checksum verification, the signature check and the
version cross-check all run for real against artifacts the test builds.
`SEMSTAT_BASE_URL` is what repoints the download root, and it takes `file://`
URLs only: a remote value is refused rather than ignored, because a composite
step inherits the job's environment and a workflow-level `env:` would otherwise
repoint both the binary and the manifest it is checked against.

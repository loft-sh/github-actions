# Semantic Version Validation Action

Reports on a version string: whether it is valid [semver](https://semver.org/),
what its parts are, which release channel it belongs to, and how it orders
against another version.

The work is done by [`semstat`](https://github.com/loft-sh/semstat), installed and
checksum-verified by
[`setup-semstat`](../setup-semstat/README.md), which is where the release pin
lives. One implementation answers for the action and for the shell scripts in this
repository, so there is no second semver engine to disagree with the first.

## Runner requirements

The action needs a Linux or macOS runner with `curl`, `tar`, `jq` and either
`sha256sum` or `shasum` on it, and egress to
`github.com/loft-sh/semstat/releases/download` **and**
`objects.githubusercontent.com`, which release-asset downloads redirect to. A
proxy allowlist that names only `github.com` fails the install step.
`verify-signature: true` adds a `cosign` download from the
`github.com/sigstore/cosign` releases and egress to `tuf-repo-cdn.sigstore.dev`,
where cosign fetches the trusted root it checks the transparency log against.

Calling it leaves the caller's `PATH` alone. The installer it shares with
[`setup-semstat`](../setup-semstat/README.md) can put semstat there, and does for
callers that run it as a bare command, but this action names the binary by absolute
path and asks the installer to skip the append, so a job with its own semstat on
`PATH` keeps resolving to that one.

All of that is new, so the rewrite ships as `semver-validation/v4`. The tags before
it (`v1`, `v2` and `v3`) all point at the self-contained Node action, which needed
neither the network nor those tools. A caller on a runner without egress keeps
working on those tags and fails the install step on `v4`, so all three stay where
they are and none is advanced onto this rewrite. Live
callers pin `v1` and `v3` as floating tags, so advancing either would hand them the
network and tool requirements with no version change to notice.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT       |  TYPE  | REQUIRED |  DEFAULT  |                                                                                                                                                                                     DESCRIPTION                                                                                                                                                                                      |
|------------------|--------|----------|-----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    compare_to    | string |  false   |           |                                                                                                                                                 Second version to order `version` against. <br>Leave empty to skip the comparison.                                                                                                                                                   |
| verify-signature | string |  false   | `"false"` | Verify the semstat release's `checksums.txt` against <br>its cosign bundle before trusting it, <br>proving the release came from semstat's <br>own release workflow at that exact <br>tag rather than only that the <br>download arrived intact. Costs a cosign <br>install on the job, so it <br>is off by default; turn it <br>on where this action's answer gates <br>a publish.  |
|     version      | string |   true   |           |                                                                                                                                                                Version string to validate against semver <br>format                                                                                                                                                                  |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|     OUTPUT     |  TYPE  |                                                                               DESCRIPTION                                                                               |
|----------------|--------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     build      | string |                                  Build metadata without the leading plus. <br>Empty when absent and when the <br>version is invalid.                                    |
|   comparison   | string |                                 -1, 0 or 1 as version <br>sorts below, equal to, or above <br>compare_to. Empty unless both are valid.                                  |
| error_message  | string |                                                                    Error message if validation fails                                                                    |
|   is_greater   | string |                                     Whether version sorts strictly above compare_to <br>(true/false). Empty unless both are valid.                                      |
|   is_stable    | string |                               Whether the version carries no prerelease <br>suffix (true/false). Empty when the version <br>is invalid.                                 |
|    is_valid    | string |                                                         Whether the version is a valid <br>semver (true/false)                                                          |
|     major      | string |                                                      Major version number. Empty when the <br>version is invalid.                                                       |
|     minor      | string |                                                      Minor version number. Empty when the <br>version is invalid.                                                       |
| parsed_version | string |                                           Parsed version object with major, minor, <br>patch, prerelease, and build metadata                                            |
|     patch      | string |                                                      Patch version number. Empty when the <br>version is invalid.                                                       |
|   prerelease   | string |                             Prerelease identifiers without the leading hyphen. <br>Empty for a stable version and <br>for an invalid one.                               |
|  release_type  | string | Release channel: stable, alpha, beta, rc, <br>next or next-internal. Empty when the <br>version is invalid, or valid semver <br>with a suffix outside that vocabulary.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

### Validate a version

```yaml
- name: Validate semver
  id: semver
  uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v4
  with:
    version: '1.2.3'

- name: Proceed
  if: steps.semver.outputs.is_valid == 'true'
  run: echo "Releasing ${{ steps.semver.outputs.major }}.${{ steps.semver.outputs.minor }}"

- name: Stop
  if: steps.semver.outputs.is_valid == 'false'
  run: |
    echo "::error::${{ steps.semver.outputs.error_message }}"
    exit 1
```

An invalid version is an answer, not a failure: the step stays green and sets
`is_valid` to `false`, so the caller decides what that means. The step fails only
when it cannot answer at all: an empty `version`, a semstat release that could not
be installed, or a semstat that did not run. `version` and `compare_to` are trimmed
before they are read, so surrounding whitespace does not change the answer, and a
`version` that is only whitespace is an invalid version rather than a missing one.
A binary that crashed must not report `is_valid=false` for a perfectly good tag,
so each call names the exit codes that are answers for it and treats anything else
as a broken environment.

### Route a tag to a channel

```yaml
- name: Classify the tag
  id: semver
  uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v4
  with:
    version: ${{ github.ref_name }}

- name: Publish the stable artifacts
  if: steps.semver.outputs.release_type == 'stable'
  run: ./hack/publish-stable.sh

- name: Publish to the prerelease channel
  if: contains(fromJSON('["alpha","beta","rc"]'), steps.semver.outputs.release_type)
  run: ./hack/publish-prerelease.sh
```

`release_type` is one of `stable`, `alpha`, `beta`, `rc`, `next` or
`next-internal`, and the counter is part of the shape: `-rc.2` is an `rc` where a
bare `-rc` is not. A version that is valid semver but carries a suffix outside
that vocabulary gets an empty `release_type`, because a release nobody knows how
to route must not be sorted into the closest-looking branch. That is said in the
log rather than as a warning annotation: the version is valid, so a caller reading
only `is_valid` has nothing to act on. Gate on `release_type == 'stable'` rather
than on `!= 'rc'` and an unroutable tag falls out rather than through.

`is_stable` answers the narrower question of whether there is a prerelease suffix
at all, and is set for every valid version including the unroutable ones.

### Order two versions

```yaml
- name: Is this tag newer than what is released?
  id: semver
  uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v4
  with:
    version: ${{ github.ref_name }}
    compare_to: ${{ steps.latest.outputs.tag }}

- name: Move the floating tag
  if: steps.semver.outputs.is_greater == 'true'
  run: ./hack/move-latest.sh
```

Ordering follows semver precedence, which `sort -V` does not: build metadata
never affects it, and a prerelease always sorts below its final release, so
`v4.9.0-rc.2` does not outrank `v4.9.0`. `comparison` is `-1`, `0` or `1`;
`is_greater` is strict, so equal versions are not greater. Both are empty when
`compare_to` is omitted or is not a version, which is not the same as `false`, so
gate on `is_greater == 'true'`.

### Verify who produced the semstat release

```yaml
- name: Is this tag newer than what is released?
  id: semver
  uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v4
  with:
    version: ${{ github.ref_name }}
    compare_to: ${{ steps.latest.outputs.tag }}
    verify-signature: true
```

The release `checksums.txt` proves the download arrived intact and resolved inside
the release asked for, but it comes from the same place as the archive, so it says
nothing about who published either. `verify-signature: true` installs `cosign` and
checks `checksums.txt` against its Sigstore bundle at the exact signing identity
before reading it; [`setup-semstat`](../setup-semstat/README.md) documents the
identity and the cost. It is off by default because it adds a cosign install to
every job. Turn it on where this action's answer gates a publish.

## From a shell script

The action is a workflow step, so it cannot be called from inside a loop or a
shell function. Put semstat on `PATH` with
[`setup-semstat`](../setup-semstat/README.md) — or, outside a workflow, [install
it](https://github.com/loft-sh/semstat#install) — and call it directly instead:

```bash
newest=""
while read -r tag; do
  semstat validate "$tag" 2>/dev/null || continue
  if [ -z "$newest" ] || semstat gt "$tag" "$newest"; then
    newest="$tag"
  fi
done < <(git tag -l 'v*')
echo "$newest"
```

`gt` exits 0 for yes, 1 for no and 2 when a version could not be read, so a typo
is distinguishable from a legitimate "not newer". Read the codes rather than the
condition alone when that matters:

```bash
if semstat gt "$candidate" "$current"; then
  echo newer
elif [ $? -eq 1 ]; then
  echo "not newer"
else
  exit 1
fi
```

## Upgrading the semstat release

There is no `semstat_version` input: the pin lives in
[`setup-semstat`](../setup-semstat/README.md), so Renovate opens one bump there
rather than one per action that runs semstat. `setup-semstat` verifies the archive
against the release checksums and refuses a binary that reports a different version
than the one asked for, so a mismatched or truncated download fails the step rather
than answering wrongly.

The installer runs out of the same checkout as this action rather than through a
`uses:` pin, so a Renovate bump of the release and a fix to the installer both
reach this action in the commit that makes them. See
[`setup-semstat`](../setup-semstat/README.md) for why a sibling in the same
repository cannot be pinned by SHA without stranding it.

## Development

```bash
make test-semver-validation   # bats suite for report.sh
make lint                     # actionlint + zizmor
make generate-docs            # refresh the tables above from action.yml
```

`src/report.sh` runs semstat and writes the outputs; installing it is
`setup-semstat`'s job and is tested there. semstat itself is stubbed in these
tests, because what its answers should be is settled by [its own
suite](https://github.com/loft-sh/semstat); what is tested here is the
translation into action outputs. `test-semver-validation.yaml` also runs the
action end to end against the real release.

# Linear Release Sync

A GitHub Action that syncs Linear issues to the "Released" state when a GitHub release is published. It finds all PRs between two releases, extracts Linear issue IDs from PR descriptions and branch names, and moves matching issues from "Ready for Release" to "Released".

## Features

- Fetches all team keys from Linear to filter false positive issue IDs (e.g. `pr-3354`, `snap-1`)
- Extracts Linear issue IDs from PR descriptions and branch names (e.g., `ENG-1234`, `DEVOPS-471`)
- Strict time-based filtering: only includes PRs merged before the release was published
- Moves issues from "Ready for Release" to "Released" state
- Adds release comments with version and date
- For stable releases on already-released issues, adds "Now available in stable release" comments
- Skips CVE issues automatically
- Supports dry-run mode for previewing changes

## Usage

Add to your release workflow:

```yaml
sync_linear:
  if: ${{ !contains(needs.publish.outputs.semver_parsed, '-next') }}
  needs: [publish]
  runs-on: ubuntu-latest
  steps:
    - name: Sync Linear issues
      uses: loft-sh/github-actions/.github/actions/linear-release-sync@linear-release-sync/v1
      with:
        release-tag: ${{ needs.publish.outputs.release_version }}
        repo-name: vcluster
        github-token: ${{ secrets.GH_ACCESS_TOKEN }}
        linear-token: ${{ secrets.LINEAR_TOKEN }}
```

## Configuration

### Required Inputs

| Input         | Description                                     |
|---------------|-------------------------------------------------|
| release-tag   | The tag of the new release (e.g. `v1.2.0`)     |
| repo-name     | The GitHub repository name                      |
| github-token  | GitHub token with read access to the repository |
| linear-token  | Linear API token for updating issues            |

### Optional Inputs

| Input                        | Default              | Description                                                |
|------------------------------|----------------------|------------------------------------------------------------|
| repo-owner                   | `loft-sh`            | The GitHub owner of the repository                         |
| previous-tag                 | *(auto-detected)*    | The previous release tag                                   |
| released-state-name          | `Released`           | The Linear workflow state name for released issues         |
| ready-for-release-state-name | `Ready for Release`  | The Linear workflow state name for issues ready to release |
| linear-teams                 | *(all teams)*        | Comma-separated list of Linear team names to process       |
| linear-projects              | *(all projects)*     | Comma-separated list of Linear project names to process    |
| strict-filtering             | `true`               | Only include PRs merged before the release was published   |
| dry-run                      | `false`              | Preview changes without modifying Linear                   |
| debug                        | `false`              | Enable debug logging                                       |

## Development

### Testing

Run the included unit tests:

```bash
make test-linear-release-sync
```

### Building locally

```bash
make build-linear-release-sync
```

### Releasing

The action runs a pre-built binary downloaded from a GitHub release at runtime (no Go toolchain needed in consumer workflows). The `release-linear-release-sync.yaml` workflow builds the binary and attaches it to a GitHub release.

**New major/minor version** (e.g. first release, or `v2`):

```bash
git tag linear-release-sync/v1
git push origin linear-release-sync/v1
```

This triggers the workflow automatically via `on: push: tags`.

**Update an existing version** (e.g. rebuild `v1` after a source change):

Force-pushing an existing tag does not trigger `on: push: tags` in GitHub Actions. Use `workflow_dispatch` instead:

```bash
# Via GitHub CLI
gh workflow run release-linear-release-sync.yaml -f tag=linear-release-sync/v1

# Or use the "Run workflow" button in the GitHub Actions UI
```

The workflow builds the binary from the branch it is dispatched against and uploads it to the existing release with `--clobber`.

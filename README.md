# github-actions

Reusable GitHub Actions

## Available Actions

### Semver Validation Action

Validates whether a given version string follows semantic versioning (semver) format.

**Location:** `.github/actions/semver-validation`

**Usage:**

```yaml
- name: Validate version
  id: semver
  uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v1
  with:
    version: '1.2.3'

- name: Check if valid
  run: echo "Valid: ${{ steps.semver.outputs.is_valid }}"
```

**Inputs:**

- `version` (required): Version string to validate

**Outputs:**

- `is_valid`: Whether the version is valid semver (`true`/`false`)
- `parsed_version`: JSON object with parsed version components
- `error_message`: Error message if validation fails

See [semver-validation README](./.github/actions/semver-validation/README.md) for detailed documentation.

## Versioning Actions

### Release-notification Action

The existing release-notification action uses a repository-wide tag:

```bash
git tag -f v1
git push origin v1 --force
```

Referenced as:

```yaml
uses: loft-sh/github-actions/release-notification@v1
```

### New Actions

For all new actions, we use action-specific tags for independent versioning:

```bash
# For the ci-notify-nightly-tests action
git tag -f ci-notify-nightly-tests/v1
git push origin ci-notify-nightly-tests/v1 --force

# For the semver-validation action
git tag -f semver-validation/v1
git push origin semver-validation/v1 --force

# For other actions, follow the same pattern
git tag -f action-name/v1
git push origin action-name/v1 --force
```

### Referencing Actions in Workflows

```yaml
# Reference actions using their specific tag
uses: loft-sh/github-actions/.github/actions/ci-notify-nightly-tests@ci-notify-nightly-tests/v1
uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v1
```


# github-actions
Reusable GitHub Actions

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

# For other actions, follow the same pattern
git tag -f action-name/v1
git push origin action-name/v1 --force
```

### Referencing Actions in Workflows

```yaml
# Reference actions using their specific tag
uses: loft-sh/github-actions/.github/actions/ci-notify-nightly-tests@ci-notify-nightly-tests/v1
```


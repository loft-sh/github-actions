# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build/Lint/Test Commands
- Run all tests: `make test`
- Test semver-validation: `make test-semver-validation`
- Test linear-pr-commenter: `make test-linear-pr-commenter`
- Test linear-release-sync: `make test-linear-release-sync`
- Build linear-release-sync binary: `make build-linear-release-sync`
- Lint workflows: `make lint` (requires actionlint and zizmor)

## Code Style Guidelines
- See [docs/CONVENTIONS.md](docs/CONVENTIONS.md) for pipeline constraints and conventions
- Follow GitHub Actions YAML best practices
- Use descriptive names for action inputs, outputs, and steps
- Document each action with clear descriptions and examples
- Maintain backward compatibility when updating actions
- Use semantic versioning for action releases
- Keep actions focused on a single responsibility
- Use input validation and provide helpful error messages

## Release Process

Actions use per-action tags (e.g. `semver-validation/v1`, `linear-release-sync/v1`).

### YAML-only / Node.js actions (semver-validation, release-notification, etc.)
- Update code and commit changes
- Tag the release: `git tag -f <action-name>/v1`
- Push tag: `git push origin <action-name>/v1 --force`

### Go actions with pre-built binaries (linear-release-sync)
These actions download a pre-built binary from a GitHub release at runtime.
- **New version**: push a new tag (`git tag linear-release-sync/v1 && git push origin linear-release-sync/v1`) — triggers `release-linear-release-sync.yaml` automatically
- **Update existing version**: force-pushing a tag does NOT trigger workflows — use `workflow_dispatch` instead: `gh workflow run release-linear-release-sync.yaml -f tag=linear-release-sync/v1`

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build/Lint/Test Commands
- Run all tests: `make test`
- Test semver-validation: `make test-semver-validation`
- Test linear-pr-commenter: `make test-linear-pr-commenter`
- Lint workflows: `make lint` (requires actionlint and zizmor)

## Code Style Guidelines
- Follow GitHub Actions YAML best practices
- Use descriptive names for action inputs, outputs, and steps
- Document each action with clear descriptions and examples
- Maintain backward compatibility when updating actions
- Use semantic versioning for action releases
- Keep actions focused on a single responsibility
- Use input validation and provide helpful error messages

## Release Process
- Update code and commit changes
- Tag the release: `git tag -f v1`
- Push tag: `git push origin v1 --force`
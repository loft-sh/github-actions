# Semantic Version Validation Action

This GitHub Action validates whether a given version string follows the [Semantic Versioning (semver)](https://semver.org/) specification.

## Features

- ✅ Validates version strings against semver format
- 📊 Returns detailed parsing information for valid versions
- 🔍 Provides clear error messages for invalid versions
- 🚀 Fast execution using the trusted `semver` npm package

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `version` | Version string to validate against semver format | Yes | - |

## Outputs

| Name | Description | Example |
|------|-------------|---------|
| `is_valid` | Whether the version is valid semver (`true`/`false`) | `true` |
| `parsed_version` | JSON object with parsed version components | `{"major":1,"minor":2,"patch":3,...}` |
| `error_message` | Error message if validation fails | `Invalid semver format: 'v1.2'` |

## Usage

### Basic Example

```yaml
name: Validate Version
on: [push, pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - name: Validate semver
        id: semver
        uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v1
        with:
          version: '1.2.3'

      - name: Check result
        run: |
          echo "Is valid: ${{ steps.semver.outputs.is_valid }}"
          echo "Parsed: ${{ steps.semver.outputs.parsed_version }}"
```

### Conditional Logic Example

```yaml
name: Release Workflow
on:
  push:
    tags:
      - 'v*'

jobs:
  validate-and-release:
    runs-on: ubuntu-latest
    steps:
      - name: Extract version from tag
        id: version
        run: echo "version=${GITHUB_REF#refs/tags/v}" >> $GITHUB_OUTPUT

      - name: Validate version
        id: semver
        uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v1
        with:
          version: ${{ steps.version.outputs.version }}

      - name: Proceed with release
        if: steps.semver.outputs.is_valid == 'true'
        run: echo "Releasing version ${{ steps.version.outputs.version }}"

      - name: Fail on invalid version
        if: steps.semver.outputs.is_valid == 'false'
        run: |
          echo "Error: ${{ steps.semver.outputs.error_message }}"
          exit 1
```

### Working with Parsed Version

```yaml
- name: Validate and parse version
  id: semver
  uses: loft-sh/github-actions/.github/actions/semver-validation@semver-validation/v1
  with:
    version: '2.1.0-alpha.1+build.123'

- name: Use parsed components
  run: |
    echo "Major: $(echo '${{ steps.semver.outputs.parsed_version }}' | jq -r '.major')"
    echo "Minor: $(echo '${{ steps.semver.outputs.parsed_version }}' | jq -r '.minor')"
    echo "Patch: $(echo '${{ steps.semver.outputs.parsed_version }}' | jq -r '.patch')"
    echo "Prerelease: $(echo '${{ steps.semver.outputs.parsed_version }}' | jq -r '.prerelease')"
```

## Valid Semver Examples

- `1.0.0`
- `1.2.3`
- `10.20.30`
- `1.1.2-prerelease+meta`
- `1.1.2+meta`
- `1.1.2+meta-valid`
- `1.0.0-alpha`
- `1.0.0-beta`
- `1.0.0-alpha.beta`
- `1.0.0-alpha.1`
- `1.0.0-alpha0.valid`
- `1.0.0-alpha.0valid`
- `1.0.0-alpha-a.b-c-somethinglong+metadata+meta.meta.meta`

## Invalid Examples

- `1`
- `1.2`
- `1.2.3-0123`
- `1.2.3-0123.0123`
- `1.1.2+.123`
- `+invalid`
- `-invalid`
- `-invalid+invalid`
- `alpha`
- `1.2.3.DEV`
- `1.2-SNAPSHOT`

## Parsed Version Object

For valid semver versions, the `parsed_version` output contains:

```json
{
  "major": 1,
  "minor": 2,
  "patch": 3,
  "prerelease": "alpha.1",
  "build": "build.123",
  "raw": "1.2.3-alpha.1+build.123"
}
```

- `major`, `minor`, `patch`: Integer version numbers
- `prerelease`: String of prerelease identifiers (null if none)
- `build`: String of build metadata (null if none)
- `raw`: Original input version string

## Error Handling

The action will:

- Set `is_valid` to `false` for invalid versions
- Provide descriptive error messages in `error_message`
- Log warnings for invalid versions
- Fail the action only on unexpected errors (not validation failures)

## Dependencies

This action uses:

- `@actions/core` for GitHub Actions integration
- `semver` for robust semver validation and parsing

## Development

### Building the Action

This action uses `@vercel/ncc` to bundle all dependencies into a single file for GitHub Actions:

```bash
npm install
npm run build
```

The bundled output is generated in `dist/index.js` and must be committed to the repository.

### Making Changes

1. Edit the source code in `index.js`
2. Run `npm run build` to create the bundled version
3. Commit both the source and bundled files
4. Create/update the action tag

### Testing Locally

You can test the action locally using environment variables:

```bash
# Test with valid semver
INPUT_VERSION="1.2.3" node dist/index.js

# Test with invalid semver
INPUT_VERSION="invalid" node dist/index.js
```

### Running Tests

The action includes comprehensive tests using Jest:

```bash
# Run all tests
npm test

# Run tests with coverage
npm test -- --coverage
```

Tests cover:

- Valid semver versions (basic, with prefixes, prerelease, build metadata)
- Invalid semver versions (incomplete, non-numeric, malformed)
- Edge cases (large numbers, the original failing case)
- Error handling

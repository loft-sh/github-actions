# Linear PR Commenter

A GitHub Action that automatically comments on PRs with Linear issue details when Linear issue IDs are detected in PR descriptions or branch names.

## Features

- Fetches all team IDs directly from Linear for accurate issue detection
- Detects Linear issue IDs in PR descriptions and branch names (e.g., `ENG-1234`, `OPS-160`)
- Works with any team key format (2+ letters) and issue number format
- Fetches Linear issue details (title, URL)
- Adds a comment to the PR with issue information as a clickable link
- Checks for existing comments to avoid duplicates
- Skips CVE IDs

## Behavior

- When a PR is created or edited, the action scans for Linear issue IDs
- First, it fetches all team keys from Linear to ensure it only detects valid issue IDs
- If an issue ID is found and no comment exists for it yet, a new comment is added
- If a comment for an issue ID already exists, no duplicate comment is created
- Comments are never removed, even if the issue ID is removed from the PR
- Each issue ID gets its own separate comment
- The comment shows the issue ID and title as a clickable link to the Linear issue

## Usage

Create a workflow file in your repository:

```yaml
name: Linear PR Comment

on:
  pull_request:
    types: [opened, edited]

jobs:
  linear-comment:
    runs-on: ubuntu-latest
    steps:
      - name: Comment on PR with Linear issue details
        uses: loft-sh/github-actions/.github/actions/linear-pr-commenter@linear-pr-commenter/v1
        with:
          pr-number: ${{ github.event.pull_request.number }}
          repo-owner: ${{ github.repository_owner }}
          repo-name: ${{ github.event.repository.name }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          linear-token: ${{ secrets.LINEAR_TOKEN }}
```

## Configuration

### Required Inputs

| Input         | Description                                     |
|---------------|-------------------------------------------------|
| pr-number     | The pull request number                         |
| repo-owner    | The owner of the repository                     |
| repo-name     | The name of the repository                      |
| github-token  | GitHub token with permissions to comment on PRs |
| linear-token  | Linear API token for retrieving issue details   |

### Setting up Linear API Token

1. In Linear, go to your account settings
2. Navigate to "API" section
3. Create a new API key
4. Add this key as a secret in your GitHub repository settings named `LINEAR_TOKEN`

## Example

When the action detects a Linear issue ID in a PR (e.g., `OPS-160`), it will add a comment like:

```
[OPS-160: Implement documentation structure](https://linear.app/team/issue/OPS-160)
```

The entire issue ID and title is a clickable link that takes you directly to the Linear issue.

## Development

### Testing

Run the included tests:

```bash
./test.sh
```

The tests are fully mocked and don't require any GitHub or Linear API credentials.

### Contributors

- Loft Engineering Team

## License

MIT
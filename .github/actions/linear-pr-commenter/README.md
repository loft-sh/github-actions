# Linear PR Commenter

A GitHub Action that automatically comments on PRs with Linear issue details when Linear issue IDs are detected in PR descriptions or branch names.

## Features

- Fetches all team IDs directly from Linear for accurate issue detection
- Detects Linear issue IDs in PR descriptions and branch names (e.g., `ENG-1234`, `OPS-160`)
- Adds a comment to the PR with issue information as a clickable link
- Checks for existing comments to avoid duplicates

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

## Example

When the action detects a Linear issue ID in a PR (e.g., `OPS-160`), it will add a comment like:

```
[OPS-160: Implement documentation structure](https://linear.app/team/issue/OPS-160)
```

The entire issue ID and title is a clickable link that takes you directly to the Linear issue.

## Development

### Testing

Run the included unit tests:

```bash
./test.sh
```

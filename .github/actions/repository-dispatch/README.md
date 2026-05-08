# Repository Dispatch

Sends a `repository_dispatch` event to a target repository so any source repo
can trigger any event type with one mechanical step. Domain-agnostic — the
caller chooses the event-type and payload schema, the receiver routes on
them. Uses the GitHub CLI (`gh`), pre-installed on hosted runners.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|    INPUT    |  TYPE  | REQUIRED | DEFAULT |                                                      DESCRIPTION                                                      |
|-------------|--------|----------|---------|-----------------------------------------------------------------------------------------------------------------------|
| event-type  | string |   true   |         |           event_type that the receiver workflow listens <br>for in its on.repository_dispatch.types list.             |
|   payload   | string |  false   | `"{}"`  | JSON object string sent as client_payload. <br>Must be a JSON object (not an array or scalar). <br>Defaults to "{}".  |
| target-repo | string |   true   |         |                               Target repository in owner/name form to <br>dispatch to.                                |

<!-- AUTO-DOC-INPUT:END -->

## Usage

```yaml
jobs:
  notify-docs:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Notify vcluster-docs of release
        uses: loft-sh/github-actions/.github/actions/repository-dispatch@repository-dispatch/v1
        with:
          target-repo: loft-sh/vcluster-docs
          event-type: vcluster-released
          payload: |
            {
              "version": "${{ github.ref_name }}",
              "sha": "${{ github.sha }}"
            }
        env:
          GH_TOKEN: ${{ secrets.CROSS_REPO_DISPATCH_TOKEN }}
```

### Auth

`GH_TOKEN` must be set as an environment variable on the step (not as an
input). It must be a Personal Access Token or GitHub App token with `repo`
scope on the **target** repository — `secrets.GITHUB_TOKEN` does not have
permission to dispatch into other repos.

### Payload

`payload` is sent verbatim as `client_payload` in the
[repository_dispatch event](https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event).
It must be a JSON object (not an array, not a scalar) — arrays and scalars
are rejected before the request is made. Receivers reference values via
`${{ github.event.client_payload.<key> }}`.

GitHub limits `client_payload` to 10 top-level properties.

### Receiver workflow

The target repository declares which `event-type` values it listens for:

```yaml
on:
  repository_dispatch:
    types: [vcluster-released]

jobs:
  apply:
    runs-on: ubuntu-latest
    steps:
      - run: echo "version=${{ github.event.client_payload.version }}"
```

Routing logic (which event-types to act on, how to interpret the payload)
lives entirely in the receiver. This action carries no domain knowledge.

## Testing

```bash
make test-repository-dispatch
```

Runs the bats suite in `test/` against `src/dispatch.sh` with a stubbed
`gh` on `PATH`.

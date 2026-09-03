# Secret broker request

Authorizes a short-lived encrypted secret request against a GitHub team, then
revalidates and claims it before a privileged issuance step loads any broker
credential.

This action treats the request commit as hostile data. It never checks out or
executes code from that commit. The authenticated actor must come from the
source workflow event.

## Request envelope

The fixed request file is a JSON object:

```json
{
  "request_version": 1,
  "request_id": "1788429600-0123456789abcdef01234567",
  "requested_secret_alias": "test-secret",
  "ephemeral_public_key": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "created_at": "2026-09-03T10:00:00Z",
  "expires_at": "2026-09-03T10:05:00Z",
  "nonce": "abcdef0123456789abcdef0123456789"
}
```

The public key is an X.509 PEM certificate with an RSA key of at least 3072
bits. Its subject must be `CN=secret-broker-request-<request_id>`, and it must
remain valid through the request expiry. Request validity is capped at ten
minutes.

The request must not contain a username. Pass the source workflow actor and
numeric actor ID from the GitHub event.

## Authorization stage

Use `operation: authorize` in a job with `contents: read`. Give this job the
GitHub App private key, but no secret-store credential. The App installation
needs only the organization permission `Members: read`.

```yaml
jobs:
  authorize:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    outputs:
      request-id: ${{ steps.broker.outputs.request-id }}
      request-sha256: ${{ steps.broker.outputs.request-sha256 }}
      public-key-fingerprint: ${{ steps.broker.outputs.public-key-fingerprint }}
      requested-secret-alias: ${{ steps.broker.outputs.requested-secret-alias }}
      created-at: ${{ steps.broker.outputs.created-at }}
      expires-at: ${{ steps.broker.outputs.expires-at }}
      nonce: ${{ steps.broker.outputs.nonce }}
    steps:
      - id: broker
        uses: loft-sh/github-actions/.github/actions/secret-broker-request@<commit-sha> # secret-broker-request/v1
        with:
          operation: authorize
          app-client-id: ${{ vars.AUTH_APP_CLIENT_ID }}
          app-private-key: ${{ secrets.AUTH_APP_PRIVATE_KEY }}
          authorization-org: YOUR_ORG
          authorization-team: secret-users
          request-repository: ${{ github.repository }}
          request-commit: ${{ github.event.workflow_run.head_sha }}
          request-branch: ${{ github.event.workflow_run.head_branch }}
          actor: ${{ github.event.workflow_run.actor.login }}
          actor-id: ${{ github.event.workflow_run.actor.id }}
          source-run-id: ${{ github.event.workflow_run.id }}
          source-run-attempt: ${{ github.event.workflow_run.run_attempt }}
          broker-run-attempt: ${{ github.run_attempt }}
          allowed-secret-aliases: test-secret
          repository-token: ${{ github.token }}
```

The action verifies the current user record still has the event's numeric ID,
then requires team membership state `active`. A pending membership is denied.

## Preflight stage

Use `operation: preflight` at the start of the issuance job. Pass only outputs
from the authorization job and trusted workflow values. The caller needs
`contents: write` so the action can create a durable processed tag.

```yaml
      - id: preflight
        uses: loft-sh/github-actions/.github/actions/secret-broker-request@<commit-sha> # secret-broker-request/v1
        with:
          operation: preflight
          request-repository: ${{ github.repository }}
          request-commit: ${{ github.event.workflow_run.head_sha }}
          request-branch: ${{ github.event.workflow_run.head_branch }}
          allowed-secret-aliases: test-secret
          repository-token: ${{ github.token }}
          trusted-commit: ${{ github.sha }}
          expected-request-id: ${{ needs.authorize.outputs.request-id }}
          expected-request-sha256: ${{ needs.authorize.outputs.request-sha256 }}
          expected-public-key-fingerprint: ${{ needs.authorize.outputs.public-key-fingerprint }}
          expected-secret-alias: ${{ needs.authorize.outputs.requested-secret-alias }}
          expected-created-at: ${{ needs.authorize.outputs.created-at }}
          expected-expires-at: ${{ needs.authorize.outputs.expires-at }}
          expected-nonce: ${{ needs.authorize.outputs.nonce }}
          request-output-file: ${{ runner.temp }}/secret-broker/request.json
          public-key-output-file: ${{ runner.temp }}/secret-broker/public.pem
```

Preflight fetches the request again by immutable commit, checks every authorized
field, then creates `refs/tags/secret-broker-processed/<request_id>`. If the tag
already exists, the action rejects the request. A failure after this claim must
use a new request. Do not delete processed tags as part of normal client
cleanup.

Load the 1Password or other secret-store credential only after preflight
succeeds. The caller owns the fixed alias-to-secret mapping, encryption, and
ciphertext transport.

## Required permissions

- Authorize: `contents: read`
- Preflight: `contents: write`
- GitHub App installation: organization `Members: read`

The action creates the App installation token only for the authorize operation.
The official token action revokes it in its post step.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|              INPUT              |  TYPE  | REQUIRED |                DEFAULT                 |                               DESCRIPTION                               |
|---------------------------------|--------|----------|----------------------------------------|-------------------------------------------------------------------------|
|              actor              | string |  false   |                                        |      GitHub-authenticated actor from the source workflow <br>run        |
|            actor-id             | string |  false   |                                        |        Stable numeric ID for the GitHub-authenticated <br>actor         |
|     allowed-secret-aliases      | string |   true   |                                        |  Comma-separated or newline-separated allowlist of secret <br>aliases   |
|          app-client-id          | string |  false   |                                        |            GitHub App client ID, required for <br>authorize             |
|         app-private-key         | string |  false   |                                        |           GitHub App private key, required for <br>authorize            |
|        authorization-org        | string |  false   |                                        |            Organization whose team membership grants access             |
|       authorization-team        | string |  false   |                                        |     Team whose active members may request <br>the allowed aliases       |
|       broker-run-attempt        | string |  false   |                                        |        Attempt number of the privileged broker <br>workflow run         |
|       expected-created-at       | string |  false   |                                        |      Authorized creation time to revalidate during <br>preflight        |
|       expected-expires-at       | string |  false   |                                        |       Authorized expiry time to revalidate during <br>preflight         |
|         expected-nonce          | string |  false   |                                        |             Authorized nonce to revalidate during preflight             |
| expected-public-key-fingerprint | string |  false   |                                        |  Authorized public key fingerprint to revalidate <br>during preflight   |
|       expected-request-id       | string |  false   |                                        |        Authorized request ID to revalidate during <br>preflight         |
|     expected-request-sha256     | string |  false   |                                        |      Authorized request digest to revalidate during <br>preflight       |
|      expected-secret-alias      | string |  false   |                                        |       Authorized secret alias to revalidate during <br>preflight        |
|         github-api-url          | string |  false   |       `"https://api.github.com"`       |                        GitHub REST API base URL                         |
|            operation            | string |  false   |             `"authorize"`              |           Request lifecycle operation, authorize or preflight           |
|      processed-ref-prefix       | string |  false   | `"refs/tags/secret-broker-processed/"` |        Durable tag prefix used to reject <br>replayed requests          |
|     public-key-output-file      | string |  false   |                                        | Private runner path for the validated <br>public key during preflight   |
|        repository-token         | string |   true   |                                        | GitHub token with contents read, plus <br>contents write for preflight  |
|         request-branch          | string |   true   |                                        |      Branch that triggered the unprivileged request <br>workflow        |
|      request-branch-prefix      | string |  false   |       `"secret-broker-request/"`       |          Trusted prefix before the timestamped request <br>ID           |
|         request-commit          | string |   true   |                                        |            Immutable commit containing the request envelope             |
|       request-output-file       | string |  false   |                                        |   Private runner path for the validated <br>request during preflight    |
|          request-path           | string |  false   |    `".secret-broker-request.json"`     |      Fixed path to the request envelope <br>in the request commit       |
|       request-repository        | string |   true   |                                        |                Repository containing the request commit                 |
|       source-run-attempt        | string |  false   |                                        |       Attempt number of the unprivileged source <br>workflow run        |
|          source-run-id          | string |  false   |                                        |             ID of the unprivileged source workflow <br>run              |
|         trusted-commit          | string |  false   |                                        |   Trusted commit used as the processed <br>tag target for preflight     |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|         OUTPUT         |  TYPE  |                     DESCRIPTION                     |
|------------------------|--------|-----------------------------------------------------|
|         actor          | string |               Authorized GitHub actor               |
|        actor-id        | string |   Stable numeric ID for the authorized <br>actor    |
|       created-at       | string |           Validated request creation time           |
|       expires-at       | string |            Validated request expiry time            |
|         nonce          | string |               Validated request nonce               |
|    public-key-file     | string | Validated public key file path from <br>preflight   |
| public-key-fingerprint | string | SHA-256 fingerprint of the request public <br>key   |
|      request-file      | string |     Validated request file path from preflight      |
|       request-id       | string |                Validated request ID                 |
|     request-sha256     | string |  SHA-256 digest of the exact request <br>envelope   |
| requested-secret-alias | string |               Validated secret alias                |
|     source-run-id      | string | Source workflow run bound to the <br>authorization  |

<!-- AUTO-DOC-OUTPUT:END -->

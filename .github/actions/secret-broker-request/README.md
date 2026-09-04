# Secret broker request

Validate a short-lived secret request from an authenticated repository user.
Revalidate and claim the same request before a privileged job loads any broker
credential.

The action treats request commits as hostile data. It fetches one fixed JSON
file by commit SHA. It never checks out or runs code from the request branch.

## Request envelope

The requester pushes `.secret-broker-request.json` on a branch named
`secret-broker-request/<request_id>`:

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

The public key must be an X.509 PEM certificate with an RSA key of at least
3072 bits. Its subject must be
`CN=secret-broker-request-<request_id>`. Requests expire after at most ten
minutes.

Do not put a username in the request. The action reads the authenticated actor
and stable actor ID from the `workflow_run` event.

## Use the action

The broker workflow must use `workflow_run` and live on the default branch.
The source request workflow must run on pushes to `secret-broker-request/**`.

```yaml
permissions: {}

on:
  workflow_run:
    workflows: [Secret request]
    types: [completed]

jobs:
  authorize:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
    outputs:
      authorization: ${{ steps.broker.outputs.authorization }}
    steps:
      - id: broker
        uses: loft-sh/github-actions/.github/actions/secret-broker-request@secret-broker-request/v1
        with:
          allowed-secret-aliases: test-secret

  issue:
    needs: authorize
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - id: preflight
        uses: loft-sh/github-actions/.github/actions/secret-broker-request@secret-broker-request/v1
        with:
          authorization: ${{ needs.authorize.outputs.authorization }}

      - name: Read, encrypt, and publish the secret
        env:
          BROKER_BUNDLE: ${{ steps.preflight.outputs.bundle }}
          OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
        run: ./scripts/publish-secret-response.sh
```

Authorization returns one opaque value. Pass it directly through the job
output. Do not parse or persist it. Preflight binds it to the same broker run,
workflow revision, source run, commit, branch, actor, and first attempt. It
then fetches the request again and checks its digest and expiry.

Preflight creates
`refs/tags/secret-broker-processed/<request-sha256>` as the single-use claim.
If the tag already exists, the request is rejected. Protect this tag namespace
with a repository ruleset. Do not delete these tags during normal cleanup.

The private bundle directory contains:

- `request.json`, the exact validated request
- `public.pem`, the validated request certificate
- `authorization.json`, the bound authorization metadata

Read the secret-store credential only in a later step after preflight succeeds.
The caller owns the fixed alias-to-secret mapping, encryption, and ciphertext
transport.

## Required permissions

- Authorize job: `contents: read`
- Issue job: `contents: write`

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|         INPUT          |  TYPE  | REQUIRED | DEFAULT |                              DESCRIPTION                              |
|------------------------|--------|----------|---------|-----------------------------------------------------------------------|
| allowed-secret-aliases | string |  false   |         | Comma-separated or newline-separated allowlist of secret <br>aliases  |
|     authorization      | string |  false   |         |      Opaque authorization returned by the authorization <br>job       |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT     |  TYPE  |                        DESCRIPTION                         |
|---------------|--------|------------------------------------------------------------|
| authorization | string | Opaque value to pass to preflight <br>in the issuance job  |
|    bundle     | string |    Private directory containing validated issuance data    |

<!-- AUTO-DOC-OUTPUT:END -->

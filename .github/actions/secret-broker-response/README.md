# Secret broker response

Retrieve the one approved secret alias from 1Password and stream its bytes
directly into CMS encryption. The action returns only a ciphertext file path.
It does not put the secret in `GITHUB_ENV`, a shell variable, an action output,
or a plaintext file.

Use this action only after `secret-broker-request` preflight succeeds in the
same privileged job. The caller owns a fixed alias-to-reference map. Requester
input must never supply or alter this map.

## Usage

```yaml
- name: Claim request
  id: preflight
  uses: loft-sh/github-actions/.github/actions/secret-broker-request@secret-broker-request/v1
  with:
    authorization: ${{ needs.authorize.outputs.authorization }}

- name: Encrypt approved secret
  id: response
  uses: loft-sh/github-actions/.github/actions/secret-broker-response@secret-broker-response/v1
  with:
    bundle: ${{ steps.preflight.outputs.bundle }}
    secret-references: |
      {
        "platform-license": "op://Automation/platform-license/license",
        "another-secret": "op://Automation/another-item/credential"
      }
    op-service-account-token: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}

- name: Publish ciphertext
  env:
    BROKER_BUNDLE: ${{ steps.preflight.outputs.bundle }}
    BROKER_CIPHERTEXT: ${{ steps.response.outputs.ciphertext }}
  run: ./scripts/publish-secret-response.sh
```

The action reads the approved alias from `authorization.json` in the preflight
bundle. It rejects aliases that have no exact key in `secret-references`.
1Password receives the service account token only in the encryption process.
The secret bytes flow through an OS pipe from `op read --no-newline` to OpenSSL.
Only the CMS DER ciphertext is written to disk.

This action performs no GitHub organization or team lookup. Authorization stays
in `secret-broker-request`, which requires repository access and active
organization membership without any team gate.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|          INPUT           |  TYPE  | REQUIRED | DEFAULT |                               DESCRIPTION                               |
|--------------------------|--------|----------|---------|-------------------------------------------------------------------------|
|          bundle          | string |   true   |         |       Private bundle returned by secret-broker-request preflight        |
| op-service-account-token | string |   true   |         | 1Password service account token used only <br>while reading the secret  |
|    secret-references     | string |   true   |         |    JSON object mapping approved aliases to <br>1Password references     |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|   OUTPUT   |  TYPE  |          DESCRIPTION           |
|------------|--------|--------------------------------|
| ciphertext | string | Path to the CMS DER ciphertext |

<!-- AUTO-DOC-OUTPUT:END -->

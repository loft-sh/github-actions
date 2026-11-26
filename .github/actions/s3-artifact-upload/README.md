# S3 artifact upload

Uploads release files to a private S3 bucket under one prefix, then a
`sha256sum` manifest of them named `SHA256SUMS`. Each object carries its
sha256 in the metadata key `sha256`.

The manifest goes last and marks the prefix as released:

- A prefix that already has a manifest is refused before anything is uploaded,
  so a released version cannot be overwritten.
- A run that fails partway leaves no manifest, so a re-run of the same tag
  overwrites the partial upload.

The check and the upload are not atomic, so each bucket and prefix must have a
single writer: one workflow in one repository, with a concurrency group per
prefix as in the example below. A `concurrency` group only serializes runs of
the same repository, so two repositories writing to the same prefix can both
pass the check before either writes its manifest.

It pairs with the `artifact-bucket` module in `loft-sh/infrastructure`, whose
upload role can put and read objects but not delete them.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

| INPUT  |  TYPE  | REQUIRED | DEFAULT |                                                         DESCRIPTION                                                         |
|--------|--------|----------|---------|-----------------------------------------------------------------------------------------------------------------------------|
| bucket | string |   true   |         |                                                   Name of the S3 bucket.                                                    |
| files  | string |   true   |         | Newline-separated paths of the files to <br>upload. Each is uploaded as <prefix>/<file <br>name>, so names must be unique.  |
| prefix | string |   true   |         |         Key prefix for the release, e.g. <br>the tag (v1.2.3). Relative, without leading <br>or trailing slashes.           |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|    OUTPUT    |  TYPE  |                                DESCRIPTION                                |
|--------------|--------|---------------------------------------------------------------------------|
| manifest-url | string | S3 URL of the uploaded manifest, <br>e.g. s3://bucket/v1.2.3/SHA256SUMS.  |

<!-- AUTO-DOC-OUTPUT:END -->

## Usage

```yaml
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: ubuntu-latest
    # One run per tag, so two runs cannot both find the prefix unreleased.
    concurrency:
      group: release-${{ github.ref_name }}
    permissions:
      contents: read
      id-token: write
    steps:
      - run: make dist
      - uses: aws-actions/configure-aws-credentials@<sha> # v6
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-example-upload
          aws-region: us-east-2
      - uses: loft-sh/github-actions/.github/actions/s3-artifact-upload@s3-artifact-upload/v1
        with:
          bucket: example-artifacts
          prefix: ${{ github.ref_name }}
          files: |
            dist/disk.tar
            dist/installer.bin
```

Readers verify a download against the manifest:

```sh
aws s3 cp s3://example-artifacts/v1.2.3/ . --recursive
sha256sum -c SHA256SUMS
```

## Permissions

The action needs AWS credentials in the environment with `s3:PutObject` and
`s3:GetObject` on the objects of the prefix and `s3:ListBucket` on the bucket.
The manifest check is a `HeadObject`, which needs `s3:GetObject`. Without
`s3:ListBucket`, S3 answers 403 instead of 404 for the missing manifest, and
the action stops rather than guess.

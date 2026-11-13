# Delete previous head image

Deletes the image a head workflow replaced, right after it pushes the new one.
Each push to a moving tag such as `head` leaves the previous image in GHCR
untagged, together with its per-platform manifests, its cosign signature and its
build provenance attestation. Nothing else removes them.

The action never guesses which untagged versions are old head images. A `record`
step reads the digest the tag points to before the build, and a `delete` step
removes exactly that image after the new one is pushed:

- the image index and the manifests it lists (platforms and BuildKit attestations)
- the referrers GHCR stores under the `sha256-<digest>` tag fallback (cosign
  signatures and `actions/attest-build-provenance` attestations), for the index
  and each manifest in it

It keeps anything that is still reachable from another tag, such as a release
whose image shares a manifest, and any version that carries a tag it did not
expect. Every manifest it keeps also keeps its signatures and attestations,
whichever reason kept it. If the previous image is still tagged (for example, promoted to a
release), it deletes nothing. It checks that against both the registry tag list
and the packages API, and if either shows a tag, it deletes nothing. Every deleted
and kept version is logged and written to the step summary.

The action fails the step on an API error. Run it last, so a failed build or push
never reaches it and a failed delete leaves the new image in place.

It deletes leaves first and the image index last. If it stops halfway, the index
is still there. Running `delete` again with the same `previous-digest` finishes
the cleanup. Re-running the whole job does not, because the job then records the
newer `head`.

## Usage

```yaml
permissions:
  contents: read
  packages: write # push, and delete versions of the package this repo publishes

steps:
  - name: Record the current head image
    id: previous-head
    uses: loft-sh/github-actions/.github/actions/delete-previous-head-image@delete-previous-head-image/v1
    with:
      mode: record
      image: ghcr.io/loft-sh/vcluster-candy

  # ... build, push, sign and attest ghcr.io/loft-sh/vcluster-candy:head ...

  - name: Delete the previous head image
    uses: loft-sh/github-actions/.github/actions/delete-previous-head-image@delete-previous-head-image/v1
    with:
      mode: delete
      image: ghcr.io/loft-sh/vcluster-candy
      previous-digest: ${{ steps.previous-head.outputs.digest }}
      current-digest: ${{ steps.build-push-docker.outputs.digest }}
```

Give the workflow a `concurrency` group with `cancel-in-progress: false`, so two
head pushes never run at once and delete each other's image.

## Permissions

The `GITHUB_TOKEN` can delete a package version only when the repo has the
`admin` role on the package. GitHub grants that role to the repo whose workflow
first published the package. For a package published another way, grant the repo
admin in the package settings. GitHub marks this `GITHUB_TOKEN` access as public
preview.

Only org-owned packages are supported.

## Limits

- It reads every tag in the package to find what must be kept, one request per
  tag. That suits packages with tens of tags, not hundreds.
- Head images pushed before a repo adopted the action stay. They can't be told
  apart from other untagged versions.
- GHCR has no atomic "check and delete". The action reads the tags, then deletes.
  A workflow that tags the previous head digest, or pushes an identical manifest,
  in that window is not seen. The head workflow's own concurrency group covers
  head pushes. Release workflows that build their own image don't touch the
  previous head digest.

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|      INPUT      |  TYPE  | REQUIRED |         DEFAULT         |                                                          DESCRIPTION                                                           |
|-----------------|--------|----------|-------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| current-digest  | string |  false   |                         |               `delete` only: the digest of the <br>image just pushed. Required when previous-digest <br>is set                 |
|     dry-run     | string |  false   |        `"false"`        |                               `delete` only: log what would be <br>deleted without deleting it                                 |
|      image      | string |   true   |                         |                             GHCR image without a tag, such <br>as ghcr.io/loft-sh/vcluster-candy                               |
|      mode       | string |   true   |                         | `record` reads the digest the tag <br>points to now; `delete` removes that <br>recorded image after the new one <br>is pushed  |
| previous-digest | string |  false   |                         |             `delete` only: the digest the `record` <br>step returned. Empty means there was <br>no previous image              |
|       tag       | string |  false   |        `"head"`         |                                          The moving tag the head workflow <br>pushes                                           |
|      token      | string |  false   | `"${{ github.token }}"` |       Token with packages:write and admin on <br>the package; the publishing repo's GITHUB_TOKEN <br>has it by default         |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

| OUTPUT |  TYPE  |                                        DESCRIPTION                                         |
|--------|--------|--------------------------------------------------------------------------------------------|
| digest | string | `record` only: the digest the tag <br>pointed to, or empty when the <br>tag did not exist  |

<!-- AUTO-DOC-OUTPUT:END -->

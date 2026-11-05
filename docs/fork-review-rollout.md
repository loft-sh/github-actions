# Fork review rollout

The [design](https://github.com/loft-sh/architecture/blob/main/engineering-enablement/designs/fork-review-check.md)
defines the control and its review rules. [DEVOPS-1792](https://linear.app/loft/issue/DEVOPS-1792)
tracks activation. A green advisory job can contain a failing receipt; use the
receipt's `pass` field to assess review coverage.

## Authentication and advisory evidence

Configure the repository secret `FORK_REVIEW_READ_TOKEN` with an approved
read-only credential scoped to the checked forks. It needs Metadata, Contents
and Pull requests read access. Product scan callers also need package read
access. Use the existing `github-token` action input or reusable-workflow secret
to supply that credential. Do not copy a developer's login token into CI or
grant a credential to PR-controlled code.

Run `Fork review advisory` on the default branch. It checks the three shipped
pins frozen in the design, rather than discovering current product inputs. It
first verifies access to each fork's collaborator
permission endpoint, then evaluates the approval rules and uploads one receipt
per fork. The `fork-review-0`, `fork-review-1` and `fork-review-2` artifacts map
to kine, tailscale and fuse. Receipts are retained for 90 days.

| Stage | Failure coverage | Existing mechanism | Evidence and remedy |
| --- | --- | --- | --- |
| Credential access | Covered: missing token, denied lookup, invalid response | `check-access.sh`, trusted default-branch workflow | Failing step names the fork and required token access; configure or repair the approved credential |
| Fork identity and input resolution | Covered: missing property, ambiguous base, unknown input, missing attestation | CLI `ref`, `go`, `image`, `binary`, `scan` modes | JSON failures and Actions summary name the unresolved input; repair the pin or fork configuration |
| Independent approval | Covered: missing PR, non-final head, ineligible approver, stale approval | CLI approval and permission checks | Receipt lists commits, PRs and approvers; obtain a qualifying fork review |
| Product advisory week | Pending product integration | Reusable `fork-review-check.yaml`, `advisory: true` | Record the first functioning product run and a full week of runs before requiring the workflow; this fixed-pin probe alone does not start that week |
| Product release receipt | Pending product integration | Action `receipt` output | Attach the JSON after the product release exists; inspect the attachment and its `pass` value on a real release |

## Activation gates

1. Verify draft-first release workflows on the actual kine and tailscale release
   branches. Build and attest assets, upload them to a draft, and verify the
   attestations before publishing. Keep binary names and signer-workflow
   mappings aligned with product consumers. Do not alter existing GHCR tags;
   their repair belongs to DEVOPS-1802.
2. Create the org-controlled `fork-upstream` property with
   `values_editable_by: org_actors`. Verify every upstream against the design
   and fork history before assigning it. Open baseline PRs from the frozen
   shipped commits into branches at their trusted upstream bases. A reviewer
   who authored none of the commits must approve them; preserve original SHAs
   with a merge commit. Record the control date and merge timestamps.
3. Enable immutable releases only after the draft-first path has built and
   verified the required assets. GitHub release immutability does not protect
   GHCR tags.
4. Integrate the check into product PR and release paths. Run product checks
   advisory for one full week. Preserve receipts and resolve unexpected
   failures before enabling a required workflow. The required workflow must
   use trusted source code and must not expose a read credential or execute a
   vendor verifier from an untrusted product PR.
5. Record the auditor's three answers in the design: CC8.1 evidence, emergency
   admin override with review within five business days, and historical
   releases as baseline evidence or dated exceptions. Update the fork pages
   with the verified release path. The security thread needs the lasting
   receipt location and release-sampling approach once those are verified.

Publishing releases, enabling enforcement, or completing a baseline review is a
separate state from merging the workflow code. Keep DEVOPS-1792 open until its
live acceptance criteria have evidence.

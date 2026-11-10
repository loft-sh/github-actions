# Fork review rollout

The [design](https://github.com/loft-sh/architecture/blob/main/engineering-enablement/designs/fork-review-check.md)
defines the control and its review rules. [DEVOPS-1792](https://linear.app/loft/issue/DEVOPS-1792)
tracks activation. A green advisory job can contain a failing receipt; use the
receipt's `pass` field to assess review coverage.

## Authentication and advisory evidence

Use an approved GitHub App installed only on the checked forks. Grant Metadata,
Contents and Pull requests read access, with no write permissions or webhooks.
The owner approves installation and repository access. See the
[Access and credentials playbook](https://app.notion.com/p/406109408069810db5b3ebb885203aae).

Create the `fork-review-advisory` GitHub Environment in this repository. Restrict
its deployment branch policy to the default branch before storing the private
key. Set its variable `FORK_REVIEW_APP_CLIENT_ID` and secret
`FORK_REVIEW_APP_PRIVATE_KEY`. Keep the private key in the approved secret store;
do not put it in source, logs or the PR body. The workflow requests a short-lived
token scoped to one fork per matrix job, with explicit read permissions. The
token is revoked at job end. A job-level ref condition and default-branch
checkout supplement the environment branch policy.

Product scan callers also need package read access. Use the existing
`github-token` action input or reusable-workflow secret to supply their approved
credential. Do not copy a developer's login token into CI or grant a credential
to PR-controlled code.

Run `Fork review advisory` on the default branch. It checks the three shipped
pins frozen in the design, rather than discovering current product inputs. It
first verifies access to each fork's collaborator
permission endpoint, then evaluates the approval rules and uploads one receipt
per fork. The `fork-review-0`, `fork-review-1` and `fork-review-2` artifacts map
to kine, tailscale and fuse. Receipts are retained for 90 days.

| Stage | Failure coverage | Existing mechanism | Evidence and remedy |
| --- | --- | --- | --- |
| Credential access | Covered: missing App configuration, denied lookup, invalid response | `check-access.sh`, protected environment, scoped App token | Failing step names the missing configuration or fork; configure or repair the approved App |
| Fork identity and input resolution | Covered: missing property, ambiguous base, unknown input, missing attestation | CLI `ref`, `go`, `image`, `binary`, `scan` modes | JSON failures and Actions summary name the unresolved input; repair the pin or fork configuration |
| Independent approval | Covered: missing PR, non-final head, ineligible approver, stale approval, commit author email linked to no GitHub account | CLI approval and permission checks; reviewed identity map `src/identities.json` | Receipt lists commits, PRs and approvers; obtain a qualifying fork review, or map an unlinked author email to its account by reviewed PR |
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

# AWS Test Infra

Provisions and tears down AWS test infrastructure (VPC + subnet + IGW +
route table + security group + EC2 instances) for e2e workflows. Replaces
hundreds of lines of duplicated Bash + `aws-cli` with a single tested Go
binary.

The action is shaped around the existing pattern in `loft-sh/vcluster-pro`:

- One VPC, one subnet, one IGW, one route table, one security group per
  workflow run, all tagged with a caller-supplied **consumer tag** plus a
  **RunID**.
- Multiple EC2 instances launched per "role" (typically `primary`,
  `worker1`, `worker2`).
- Best-effort teardown by ID, followed by a tag-based **fallback sweep**
  that catches anything left behind by a run that failed before exporting
  IDs.

## Authentication

The binary uses the default `aws-sdk-go-v2` credential chain. Calling
workflows already configured with
`aws-actions/configure-aws-credentials` (OIDC + assume-role) will pass
credentials through automatically.

## Usage

### Provision

```yaml
- name: Set up Go
  # Required: this action builds itself from source on every run.
  uses: actions/setup-go@v5
  with:
    go-version-file: go.mod  # or whatever your repo uses

- name: AWS login (OIDC)
  uses: aws-actions/configure-aws-credentials@v5.1.1
  with:
    role-to-assume: arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/e2e-test-executor
    aws-region: us-west-2

- name: Provision e2e infra
  id: provision
  uses: loft-sh/github-actions/.github/actions/aws-test-infra@aws-test-infra/v1
  with:
    command: provision
    region: us-west-2
    run-id: selinux-e2e-${{ github.run_id }}-${{ matrix.os }}
    consumer-tag: SELinuxE2E=true
    sg-name: selinux-e2e-${{ github.run_id }}-${{ matrix.os }}
    sg-description: SELinux e2e suite
    ami-owner: ${{ matrix.ami_owner }}
    ami-filter: ${{ matrix.ami_filter }}
    root-device: ${{ matrix.ami_root_device }}
    volume-size-gb: '200'
    instance-profile: e2e-test-executor
    ssm-wait-timeout: 5m
    ssm-wait-interval: 10s
    ingress-rules: |
      -1:-1:-1:10.0.0.0/16
      tcp:8443:8443:0.0.0.0/0
      tcp:30000:32767:0.0.0.0/0
      icmp:-1:-1:10.0.0.0/16
    user-data: |
      #!/bin/bash
      set -e
      dnf install -y https://s3.us-west-2.amazonaws.com/amazon-ssm-us-west-2/latest/linux_amd64/amazon-ssm-agent.rpm
      systemctl enable --now amazon-ssm-agent

- name: Use the infra
  env:
    PRIMARY_PUBLIC_IP: ${{ steps.provision.outputs.primary-public-ip }}
    PRIMARY_INSTANCE_ID: ${{ steps.provision.outputs.primary-instance-id }}
  run: ...
```

The action populates `outputs.vpc-id`, `outputs.subnet-id`, etc. — see the
inputs/outputs section below for the full list.

### Cleanup

Cleanup must run with `if: always()` so that resources are torn down even
when the test run failed.

```yaml
- name: Cleanup e2e infra
  if: always()
  uses: loft-sh/github-actions/.github/actions/aws-test-infra@aws-test-infra/v1
  with:
    command: cleanup
    region: us-west-2
    run-id: selinux-e2e-${{ github.run_id }}-${{ matrix.os }}
    vpc-id: ${{ steps.provision.outputs.vpc-id }}
    igw-id: ${{ steps.provision.outputs.igw-id }}
    subnet-id: ${{ steps.provision.outputs.subnet-id }}
    route-table-id: ${{ steps.provision.outputs.route-table-id }}
    route-assoc-id: ${{ steps.provision.outputs.route-assoc-id }}
    security-group-id: ${{ steps.provision.outputs.security-group-id }}
    instance-ids: ${{ steps.provision.outputs.instance-ids }}
```

If the provision step failed before producing IDs, leave them blank — the
tag-based sweep will find any orphaned resources by `tag:RunID` and clean
them up.

### Variable instance count or non-standard role names

The defaults launch three instances tagged `primary`, `worker1`, `worker2`,
with named outputs (`primary-instance-id`, `worker1-instance-id`,
`worker2-instance-id`) for each. To launch a different count or use
arbitrary role names, override `instance-roles` and read the IDs from the
`instance-id-by-role` JSON output.

```yaml
- name: Provision (2 instances, custom roles)
  id: provision
  uses: loft-sh/github-actions/.github/actions/aws-test-infra@aws-test-infra/v1
  with:
    command: provision
    region: us-west-2
    run-id: my-suite-${{ github.run_id }}
    consumer-tag: MySuite=true
    sg-name: my-suite-${{ github.run_id }}
    ami-owner: '099720109477'
    ami-filter: 'ubuntu/images/hvm-ssd*/ubuntu-jammy-22.04-amd64-server-*'
    instance-roles: 'controller,agent'

- name: Use instances
  env:
    CONTROLLER_ID: ${{ fromJSON(steps.provision.outputs.instance-id-by-role).controller }}
    AGENT_ID: ${{ fromJSON(steps.provision.outputs.instance-id-by-role).agent }}
  run: ...
```

The `instance-ids` output (CSV) and the cleanup wiring continue to work
unchanged for any role count.

### S3 staging, download, and cleanup

For workflows that hand artifacts to EC2 instances over S3 (image tarballs,
binaries) and collect results back, three S3 subcommands cover the bucket
lifecycle. The presigned URLs are generated with the AWS SDK, which produces
both GET **and** PUT URLs natively — no `boto3` shim needed.

**`s3-stage`** ensures (and tags) a run-scoped bucket, uploads local files,
and returns presigned URLs as a JSON map:

```yaml
- name: Stage artifacts on S3
  id: s3
  uses: loft-sh/github-actions/.github/actions/aws-test-infra@aws-test-infra/v1
  with:
    command: s3-stage
    region: us-west-2
    run-id: conformance-standalone-${{ github.run_id }}-${{ github.run_attempt }}
    expires-in: 4h
    uploads: |
      vcluster_image=vcluster.tar
      /tmp/kind-node.tar.gz=kind-node.tar.gz
    presign: |
      vcluster.tar:get
      kind-node.tar.gz:get
      results.tar.gz:put

- name: Use the URLs
  env:
    IMAGE_BUCKET: ${{ steps.s3.outputs.bucket }}
    VCLUSTER_IMAGE_URL: ${{ fromJSON(steps.s3.outputs.presigned-urls)['vcluster.tar'] }}
    KIND_NODE_IMAGE_URL: ${{ fromJSON(steps.s3.outputs.presigned-urls)['kind-node.tar.gz'] }}
    RESULTS_PUT_URL: ${{ fromJSON(steps.s3.outputs.presigned-urls)['results.tar.gz'] }}
  run: ...
```

The bucket name defaults to the lowercased `run-id`; pass `bucket` to override.
Uploads that are produced by earlier steps (e.g. `docker save … | gzip`) are
written to disk by the caller and then referenced by path in `uploads`.

> **Presigned URL lifetime is capped by the AWS credential lifetime.** A
> presigned URL only works while *both* its `expires-in` window is open *and*
> the credentials that signed it are still valid. With OIDC
> (`aws-actions/configure-aws-credentials`) the STS session defaults to **1
> hour**, so an `expires-in: 4h` URL silently starts returning `403` after ~1h
> and the EC2 GET/PUT fails mid-run. For hours-long conformance runs, set
> `role-duration-seconds` on the credentials step to at least the run length,
> and make sure the IAM role's **maximum session duration** allows it.
> `s3-stage` prints a `::warning::` when it detects the requested `expires-in`
> exceeds the remaining session lifetime.
>
> The presigned URLs are also written to `$GITHUB_OUTPUT`, which Actions does
> **not** mask; `s3-stage` registers each URL with `::add-mask::` so it is
> scrubbed from subsequent logs. A leaked PUT URL is a write capability for its
> whole lifetime, so treat these outputs as secrets.

**`s3-download`** pulls an object back to a local path. A missing object is a
no-op (not an error), matching the "results only exist if the run got far
enough" semantics:

```yaml
- name: Fetch results
  if: always()
  uses: loft-sh/github-actions/.github/actions/aws-test-infra@aws-test-infra/v1
  with:
    command: s3-download
    region: us-west-2
    bucket: ${{ steps.s3.outputs.bucket }}
    key: results.tar.gz
    dest: ./results.tar.gz
```

**`s3-cleanup`** empties and deletes the bucket, with a tag-based sweep
fallback (same shape as EC2 `cleanup`). Run it with `if: always()`:

```yaml
- name: Teardown S3 bucket
  if: always()
  uses: loft-sh/github-actions/.github/actions/aws-test-infra@aws-test-infra/v1
  with:
    command: s3-cleanup
    region: us-west-2
    bucket: ${{ steps.s3.outputs.bucket }}
    run-id: conformance-standalone-${{ github.run_id }}-${{ github.run_attempt }}
    bucket-prefix: conformance-standalone-
```

If `bucket` is blank (the stage step never ran), the sweep deletes any bucket
whose name starts with `bucket-prefix` and carries the matching `RunID` tag.

## Ingress rule format

Each rule is `protocol:fromPort:toPort:cidr`. To pass several rules at
once, put one rule per line in the `ingress-rules` input.

| Protocol | fromPort | toPort | CIDR | Meaning |
|---|---|---|---|---|
| `-1` | -1 | -1 | `10.0.0.0/16` | All protocols, intra-VPC |
| `tcp` | 8443 | 8443 | `0.0.0.0/0` | vCluster API, wide-open |
| `tcp` | 30000 | 32767 | `1.2.3.4/32` | Inner NodePort range, runner-only |
| `icmp` | -1 | -1 | `10.0.0.0/16` | ICMP intra-VPC |

## Inputs

<!-- AUTO-DOC-INPUT:START - Do not remove or modify this section -->

|          INPUT           |  TYPE  | REQUIRED |           DEFAULT           |                                                                                                              DESCRIPTION                                                                                                              |
|--------------------------|--------|----------|-----------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|     ami-architecture     | string |  false   |         `"x86_64"`          |                        (provision) Architecture filter for AMI lookup <br>(e.g. x86_64, arm64). Defaults to x86_64 to match <br>the original Bash workflows; pass an <br>empty string to disable the filter.                          |
|        ami-filter        | string |  false   |                             |                                                                                (provision) AMI name filter for lookup <br>(latest CreationDate wins)                                                                                  |
|          ami-id          | string |  false   |                             |                                                                                         (provision) Use this exact AMI ID <br>(skips lookup)                                                                                          |
|        ami-owner         | string |  false   |                             |                                                                                        (provision) AMI owner (account ID or alias) for lookup                                                                                         |
| ami-virtualization-type  | string |  false   |           `"hvm"`           |                     (provision) Virtualization-type filter for AMI lookup <br>(e.g. hvm, paravirtual). Defaults to hvm to match <br>the original Bash workflows; pass an <br>empty string to disable the filter.                      |
|    availability-zone     | string |  false   |                             |                                                                                    (provision) AZ for the subnet (defaults to first AZ in region)                                                                                     |
|          bucket          | string |  false   |                             |             (s3-*) Bucket name. For s3-stage it <br>defaults to the lowercased run-id. Required <br>for s3-download. For s3-cleanup, pass the <br>bucket to delete directly and/or bucket-prefix <br>for the tag sweep.               |
|      bucket-prefix       | string |  false   |                             |                                                                                (s3-cleanup) Bucket name prefix for the <br>tag-based sweep fallback.                                                                                  |
|         command          | string |   true   |                             |                                                                              Subcommand: provision | cleanup | s3-stage <br>| s3-download | s3-cleanup                                                                                |
|       consumer-tag       | string |  false   |                             |                                                                                 (provision) Consumer tag in KEY=VALUE form, <br>e.g. SELinuxE2E=true                                                                                  |
|           dest           | string |  false   |                             |                                                                                                 (s3-download) Local destination path.                                                                                                 |
|        expires-in        | string |  false   |           `"4h"`            |                                                                              (s3-stage) Presigned URL lifetime as a <br>Go duration (e.g. 4h, 14400s).                                                                                |
|          igw-id          | string |  false   |                             |                                                                                                     (cleanup) Internet gateway ID                                                                                                     |
|      ingress-rules       | string |  false   |                             |                                           (provision) Newline-separated ingress rules in protocol:fromPort:toPort:cidr <br>form. Example: "-1:-1:-1:10.0.0.0/16\ntcp:8443:8443:0.0.0.0/0"                                             |
|       instance-ids       | string |  false   |                             |                                                                                            (cleanup) Comma-separated list of instance IDs                                                                                             |
|     instance-profile     | string |  false   |                             |                                                                                                 (provision) IAM instance profile name                                                                                                 |
|      instance-roles      | string |  false   | `"primary,worker1,worker2"` |                                                                                   (provision) Comma-separated role labels (one instance per role)                                                                                     |
| instance-running-timeout | string |  false   |           `"30m"`           |                                                                (provision) Max wait for all instances <br>to reach running state. Bump for <br>slow-boot edge cases.                                                                  |
|      instance-type       | string |  false   |        `"m5.xlarge"`        |                                                                                                     (provision) EC2 instance type                                                                                                     |
|           key            | string |  false   |                             |                                                                                                 (s3-download) Object key to download.                                                                                                 |
|         presign          | string |  false   |                             |                (s3-stage) Newline-separated object-key:method pairs to presign <br>(method get|put). Example: "vcluster.tar:get\nresults.tar.gz:put". Read the result <br>via fromJSON(outputs.presigned-urls).<key>.                 |
|          region          | string |   true   |                             |                                                                                                              AWS region                                                                                                               |
|       root-device        | string |  false   |        `"/dev/sda1"`        |                                                                                 (provision) Root block-device name, e.g. /dev/sda1 <br>or /dev/xvda                                                                                   |
|      route-assoc-id      | string |  false   |                             |                                                                                                 (cleanup) Route table association ID                                                                                                  |
|      route-table-id      | string |  false   |                             |                                                                                                       (cleanup) Route table ID                                                                                                        |
|          run-id          | string |  false   |                             |                                 Unique run identifier; tagged as RunID <br>on provisioned resources and on s3-stage <br>buckets. For s3-stage the bucket name <br>defaults to the lowercased run-id.                                  |
|    security-group-id     | string |  false   |                             |                                                                                                      (cleanup) Security group ID                                                                                                      |
|      sg-description      | string |  false   |                             |                                                                                                (provision) Security group description                                                                                                 |
|         sg-name          | string |  false   |                             |                                                                                                    (provision) Security group name                                                                                                    |
|       skip-direct        | string |  false   |          `"false"`          |                                                                                   (cleanup) Skip direct cleanup; only run <br>the tag-based sweep                                                                                     |
|      skip-ssm-wait       | string |  false   |          `"false"`          |                                                                                                (provision) Skip waiting for SSM agents                                                                                                |
|        skip-sweep        | string |  false   |          `"false"`          |                                                                      (cleanup) Skip the tag-based sweep; only <br>run direct cleanup with the supplied <br>IDs                                                                        |
|    ssm-wait-interval     | string |  false   |           `"10s"`           |                                                                                     (provision) Polling interval for SSM agent <br>registration                                                                                       |
|     ssm-wait-timeout     | string |  false   |           `"5m"`            |                                                                                   (provision) How long to wait for <br>all SSM agents to register                                                                                     |
|       strict-sweep       | string |  false   |          `"false"`          | (cleanup, s3-cleanup) Fail the step on sweep <br>errors. Default false matches the original <br>Bash teardown (set +e). Set true if <br>you would rather see sweep failures <br>than silently leak resources on AWS <br>API hiccups.  |
|       subnet-cidr        | string |  false   |       `"10.0.1.0/24"`       |                                                                                                        (provision) Subnet CIDR                                                                                                        |
|        subnet-id         | string |  false   |                             |                                                                                                          (cleanup) Subnet ID                                                                                                          |
|         uploads          | string |  false   |                             |                                        (s3-stage) Newline-separated local-path=object-key pairs to upload. <br>Example: "vcluster_image=vcluster.tar\n/tmp/kind-node.tar.gz=kind-node.tar.gz"                                         |
|        user-data         | string |  false   |                             |                                                                  (provision) Raw user-data content; written to <br>a temp file and base64-encoded by <br>the binary                                                                   |
|      volume-size-gb      | string |  false   |           `"100"`           |                                                                                                  (provision) Root volume size in GB                                                                                                   |
|         vpc-cidr         | string |  false   |       `"10.0.0.0/16"`       |                                                                                                         (provision) VPC CIDR                                                                                                          |
|          vpc-id          | string |  false   |                             |                                                                                                           (cleanup) VPC ID                                                                                                            |

<!-- AUTO-DOC-INPUT:END -->

## Outputs

<!-- AUTO-DOC-OUTPUT:START - Do not remove or modify this section -->

|       OUTPUT        |  TYPE  |                                                                                              DESCRIPTION                                                                                               |
|---------------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|       ami-id        | string |                                                                                            Resolved AMI ID                                                                                             |
|       bucket        | string |                                                                             (s3-stage) Bucket name that was ensured/used.                                                                              |
|       igw-id        | string |                                                                                      Created internet gateway ID                                                                                       |
| instance-id-by-role | string | JSON map of role → instance <br>ID. Use for arbitrary role names <br>(anything other than primary/worker1/worker2). Consumer accesses with `fromJSON(steps.<id>.outputs.instance-id-by-role).<role>`.  |
|    instance-ids     | string |                                                                                Comma-separated list of all instance IDs                                                                                |
|   presigned-urls    | string |                                        (s3-stage) JSON map of object-key → <br>presigned URL. Access with `fromJSON(steps.<id>.outputs.presigned-urls).<key>`.                                         |
| primary-instance-id | string |                                                                 Instance ID of the role labeled <br>"primary" (empty if not present)                                                                   |
|  primary-public-ip  | string |                                                                                   Public IP of the primary instance                                                                                    |
|   route-assoc-id    | string |                                                                                   Created route table association ID                                                                                   |
|   route-table-id    | string |                                                                                         Created route table ID                                                                                         |
|  security-group-id  | string |                                                                                       Created security group ID                                                                                        |
|      subnet-id      | string |                                                                                           Created subnet ID                                                                                            |
|       vpc-id        | string |                                                                                             Created VPC ID                                                                                             |
| worker1-instance-id | string |                                                                 Instance ID of the role labeled <br>"worker1" (empty if not present)                                                                   |
| worker2-instance-id | string |                                                                 Instance ID of the role labeled <br>"worker2" (empty if not present)                                                                   |

<!-- AUTO-DOC-OUTPUT:END -->

## Local development

The Go source lives at `src/`. Build and test locally:

```sh
cd src
go test ./...
go build -o /tmp/aws-test-infra .
/tmp/aws-test-infra provision -h
/tmp/aws-test-infra cleanup -h
```

## How it works (build-from-source)

The action builds the Go binary at runtime from `src/` and runs it. There
is no separate release artifact — the consumer references a tag (e.g.
`@aws-test-infra/v1`), GitHub fetches the action source at that ref, and
the action builds + invokes it in the same job.

This requires the **consumer's runner already has Go installed** (e.g.
via a prior `actions/setup-go` step). Both current consumers
(`vcluster-pro` selinux + prerelease workflows) do; if a future consumer
doesn't, the action emits a clear error.

## Releasing

Tag scheme is `aws-test-infra/v*`, e.g. `aws-test-infra/v1`. Push the tag
at the merged commit on `main`:

```sh
git tag aws-test-infra/v1
git push origin aws-test-infra/v1
```

That's it — no release workflow, no binary upload, no SHA-256 dance.
Consumers can use `@aws-test-infra/v1` immediately. Force-pushing the
tag works the same way (next consumer run picks up the new code).

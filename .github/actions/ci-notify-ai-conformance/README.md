# ci-notify-ai-conformance

Sends a Slack notification with CNCF K8s AI Conformance pipeline results.

## Usage

```yaml
- uses: loft-sh/github-actions/.github/actions/ci-notify-ai-conformance@<sha> # ci-notify-ai-conformance/v1
  with:
    status: 'success'          # or 'failure'
    k8s_version: 'v1.34'
    vcluster_version: 'v0.32.0'
    tenancy_model: 'private-nodes'
    artifact_url: 'https://github.com/...'  # optional
    webhook_url: ${{ secrets.SLACK_WEBHOOK_URL_CI_TESTS_ALERTS }}
```

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `status` | yes | Pipeline status (`success` or `failure`) |
| `k8s_version` | yes | Target Kubernetes version (e.g., `v1.34`) |
| `vcluster_version` | yes | vCluster OSS CLI version (e.g., `v0.32.0`) |
| `tenancy_model` | yes | vCluster tenancy model (`private-nodes`, `shared`, `standalone`) |
| `artifact_url` | no | URL to uploaded artifacts |
| `webhook_url` | yes | Slack incoming webhook URL |

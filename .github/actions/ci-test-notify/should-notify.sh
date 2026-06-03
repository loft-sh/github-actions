#!/usr/bin/env bash
set -euo pipefail

# Decides whether ci-test-notify should send a Slack message, writing
# `notify=true|false` to $GITHUB_OUTPUT for the composite action to gate on.
#
# Callers pass the run conclusion straight from `needs.<job>.result` or
# `job.status`, which can be success, failure, cancelled, or skipped. Only
# success and failure are actionable: a cancelled run was aborted by a human
# (or superseded), and a skipped job never executed. Neither warrants a Slack
# alert, so both are silenced here rather than in every caller.
#
# An empty webhook (fork PRs, where secrets are unavailable) also suppresses
# the notification, same as before.
#
# Required env vars: STATUS, GITHUB_OUTPUT
# Optional env vars: WEBHOOK_URL

notify=true

if [[ -z "${WEBHOOK_URL:-}" ]]; then
  echo "::warning::webhook-url is empty (expected on fork PRs where secrets are unavailable), skipping notification"
  notify=false
elif [[ "${STATUS:?STATUS is required}" == "cancelled" || "$STATUS" == "skipped" ]]; then
  echo "::notice::status is '$STATUS' — only success and failure notify, skipping Slack notification"
  notify=false
fi

echo "notify=$notify" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

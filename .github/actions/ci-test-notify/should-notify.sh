#!/usr/bin/env bash
set -euo pipefail

# Decides whether ci-test-notify should send a Slack message, writing
# `notify=true|false` to $GITHUB_OUTPUT for the composite action to gate on.
#
# Callers pass the run conclusion straight from `needs.<job>.result` or
# `job.status`, which can be success, failure, warning, cancelled, or skipped.
# Cancelled and skipped runs are silenced: a cancelled run was aborted by a
# human (or superseded), and a skipped job never executed. A warning is an
# advisory result and should notify without being labelled as a failure.
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
  echo "::notice::status is '$STATUS' — cancelled and skipped runs do not notify, skipping Slack notification"
  notify=false
fi

echo "notify=$notify" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

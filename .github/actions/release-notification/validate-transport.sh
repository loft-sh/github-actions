#!/usr/bin/env bash
# Check that the caller gave this action a way to reach Slack for the status
# it is posting. Success banners go through the bot token (chat.postMessage,
# which returns a ts for thread replies) or the incoming webhook; failure
# notifications only go through the webhook.
#
# Env: STATUS, HAS_WEBHOOK, HAS_BOT_TOKEN, HAS_CHANNEL ("true"/"false")
set -euo pipefail

if [ "${HAS_BOT_TOKEN:-false}" = true ] && [ "${HAS_CHANNEL:-false}" != true ]; then
  echo "::warning::slack_bot_token is set without slack_channel_id, so the bot token is ignored. Pass the channel id to post through the bot."
fi

if [ "${STATUS:-success}" = success ]; then
  if [ "${HAS_WEBHOOK:-false}" != true ] && { [ "${HAS_BOT_TOKEN:-false}" != true ] || [ "${HAS_CHANNEL:-false}" != true ]; }; then
    echo "::error::No Slack transport: pass webhook_url, or slack_bot_token with slack_channel_id."
    exit 1
  fi
elif [ "${HAS_WEBHOOK:-false}" != true ]; then
  echo "::error::Failure notifications post through webhook_url, which is empty."
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

# Cleans up old head chart versions from ChartMuseum, keeping the N most
# recently uploaded versions. Skips the 0.0.0-latest sentinel version.
#
# Required environment variables:
#   CHART_MUSEUM_URL       — ChartMuseum base URL (e.g. https://charts.loft.sh)
#   CHART_MUSEUM_USER      — ChartMuseum username
#   CHART_MUSEUM_PASSWORD  — ChartMuseum password
#
# Arguments:
#   $1 — chart name (required, e.g. vcluster-head)
#   $2 — max versions to keep (default: 50)
#   $3 — dry-run mode: true/false (default: false)

CHART_NAME="${1:?chart name is required}"
MAX_VERSIONS="${2:-50}"
DRY_RUN="${3:-false}"

if ! CHART_RESPONSE=$(curl -sf -u "$CHART_MUSEUM_USER:$CHART_MUSEUM_PASSWORD" \
  "$CHART_MUSEUM_URL/api/charts/$CHART_NAME"); then
  echo "Error: Failed to fetch chart versions from ChartMuseum"
  echo "This could indicate authentication failure or ChartMuseum is unreachable"
  exit 1
fi

ALL_VERSIONS=$(echo "$CHART_RESPONSE" | \
  jq -r '.[] | select(.version != "0.0.0-latest") | "\(.created) \(.version)"' | \
  sort -r)

VERSION_COUNT=$(echo "$ALL_VERSIONS" | grep -c '.' || true)
echo "Found $VERSION_COUNT head chart versions (excluding '0.0.0-latest')"

if [ "$VERSION_COUNT" -gt "$MAX_VERSIONS" ]; then
  VERSIONS_TO_DELETE=$(echo "$ALL_VERSIONS" | tail -n +"$((MAX_VERSIONS + 1))" | awk '{print $2}')
  DELETE_COUNT=$(echo "$VERSIONS_TO_DELETE" | wc -l)

  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] Would delete $DELETE_COUNT old versions (keeping $MAX_VERSIONS most recently uploaded):"
    echo "$VERSIONS_TO_DELETE"
    exit 0
  fi

  echo "Deleting $DELETE_COUNT old versions (keeping $MAX_VERSIONS most recently uploaded)..."

  DELETED=0
  for VERSION in $VERSIONS_TO_DELETE; do
    echo "Deleting version: $VERSION"
    if curl -sf -X DELETE \
      -u "$CHART_MUSEUM_USER:$CHART_MUSEUM_PASSWORD" \
      -w "\nHTTP Status: %{http_code}\n" \
      "$CHART_MUSEUM_URL/api/charts/$CHART_NAME/$VERSION"; then
      echo "Successfully deleted $VERSION"
      DELETED=$((DELETED + 1))
    else
      echo "Failed to delete $VERSION (may not exist)"
    fi
  done

  echo "Cleanup complete: deleted $DELETED/$DELETE_COUNT versions, kept $MAX_VERSIONS most recent"
else
  echo "Only $VERSION_COUNT versions found, no cleanup needed (keeping last $MAX_VERSIONS)"
fi

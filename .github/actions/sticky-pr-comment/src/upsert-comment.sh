#!/usr/bin/env bash
# Upsert a sticky PR comment identified by a stable HTML marker.
#
# Required env: GH_TOKEN, INPUT_MARKER, INPUT_BODY, INPUT_PR_NUMBER, INPUT_REPO,
#               INPUT_EXPECTED_AUTHOR
# Writes: comment-id=<id> and action-taken=created|updated to $GITHUB_OUTPUT.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${INPUT_MARKER:?marker required}"
: "${INPUT_BODY:?body required}"
: "${INPUT_PR_NUMBER:?pr-number required}"
: "${INPUT_REPO:?repo required}"
: "${INPUT_EXPECTED_AUTHOR:?expected-author required}"

# The marker must be a self-contained HTML comment so it can't accidentally
# match unrelated comments and so callers can't smuggle markdown into it.
if [[ ! "$INPUT_MARKER" =~ ^\<!--[[:space:]].*[[:space:]]--\>$ ]]; then
  echo "::error::marker must look like '<!-- some-id -->', got: $INPUT_MARKER"
  exit 1
fi

# Ensure the marker is the first line of the body so startswith() matches.
if [[ "$INPUT_BODY" == "$INPUT_MARKER"* ]]; then
  BODY="$INPUT_BODY"
else
  BODY="${INPUT_MARKER}"$'\n'"${INPUT_BODY}"
fi

emit() {
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  printf '%s=%s\n' "$1" "$2"
}

# --paginate concatenates pages into a single JSON array. Filter locally with
# jq (rather than --jq) so we're not at the mercy of per-page filtering, and
# so the marker travels as a jq --arg rather than embedded into a quoted
# filter string.
COMMENTS_JSON=$(gh api --paginate \
  "repos/${INPUT_REPO}/issues/${INPUT_PR_NUMBER}/comments")
# Match by author + marker so a third party can't squat on the sticky slot
# by pre-creating a comment whose body starts with the marker.
COMMENT_ID=$(jq -r --arg m "$INPUT_MARKER" --arg u "$INPUT_EXPECTED_AUTHOR" \
  '[.[] | select(.user.login == $u and (.body | startswith($m)))] | first | .id // empty' \
  <<<"$COMMENTS_JSON")

if [[ -n "$COMMENT_ID" ]]; then
  gh api -X PATCH \
    "repos/${INPUT_REPO}/issues/comments/${COMMENT_ID}" \
    -f body="$BODY" >/dev/null
  emit comment-id "$COMMENT_ID"
  emit action-taken "updated"
else
  CREATE_JSON=$(gh api -X POST \
    "repos/${INPUT_REPO}/issues/${INPUT_PR_NUMBER}/comments" \
    -f body="$BODY")
  COMMENT_ID=$(jq -r '.id' <<<"$CREATE_JSON")
  emit comment-id "$COMMENT_ID"
  emit action-taken "created"
fi

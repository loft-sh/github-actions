#!/usr/bin/env bash
# Resolves and validates the four version inputs for the pre-release checks.
# An empty upgrade target becomes the most recently published pre-release whose
# final release has not shipped yet; an empty base becomes the highest release
# below that target.
#
# Needs GNU coreutils: `sort -V` must rank '~' below everything, which BSD and
# macOS sort do not. The runners are Ubuntu; `make test` on a Mac will disagree.
#
# Required env: GH_TOKEN, GITHUB_OUTPUT, GITHUB_ENV
# Optional env: STANDALONE_VCLUSTER_VERSION_INPUT,
#   STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT, PLATFORM_BASE_VERSION_INPUT,
#   PLATFORM_RC_VERSION_INPUT (all default to empty), RELEASE_PAGE_LIMIT
set -euo pipefail

VERSION_RE_BODY='[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?'
VERSION_RE="^${VERSION_RE_BODY}\$"
STABLE_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
: "${RELEASE_PAGE_LIMIT:=20}"
[[ "$RELEASE_PAGE_LIMIT" =~ ^[1-9][0-9]*$ ]] \
  || { echo "RELEASE_PAGE_LIMIT must be a positive integer, got: $RELEASE_PAGE_LIMIT"; exit 1; }
: "${GITHUB_API_URL:=https://api.github.com}"

CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$CACHE_DIR"' EXIT

listing() { printf '%s/%s.json' "$CACHE_DIR" "$1"; }

# Reads a repo's whole release list into a file, once per run. The list is not
# ordered by version, so finding the highest release means reading all of it.
load_listing() {
  local repo="$1" file page=1 body count
  file="$(listing "$repo")"
  [ -f "$file" ] && return 0
  : > "$file"
  while [ "$page" -le "$RELEASE_PAGE_LIMIT" ]; do
    body="$(curl -fsSL --retry 3 --retry-delay 2 \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GH_TOKEN" \
      "${GITHUB_API_URL}/repos/loft-sh/${repo}/releases?per_page=100&page=${page}")" \
      || { echo "failed to list releases for loft-sh/${repo} (page ${page})"; exit 1; }
    count="$(printf '%s' "$body" | jq -e 'if type == "array" then length else null end' 2>/dev/null)" \
      || { echo "unexpected response listing releases for loft-sh/${repo} (page ${page})"; exit 1; }
    printf '%s\n' "$body" >> "$file"
    [ "$count" -lt 100 ] && return 0
    page=$((page + 1))
  done
  echo "release listing for loft-sh/${repo} exceeded ${RELEASE_PAGE_LIMIT} pages; refusing to resolve from a partial list"
  exit 1
}

# sort -V puts a pre-release after its own release, which is backwards for
# semver. Mapping '-' to '~' fixes it, because sort -V ranks '~' below anything.
sort_key() { printf '%s' "$1" | tr '-' '~'; }

is_below() {
  local a b
  a="$(sort_key "$1")"
  b="$(sort_key "$2")"
  [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$b" ]
}

# Highest of the versions on stdin.
highest_of() {
  local best="" candidate
  while read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -z "$best" ] || is_below "$best" "$candidate"; then best="$candidate"; fi
  done
  printf '%s' "$best"
}

# Emits "published_at<TAB>version" so callers can order explicitly.
pre_release_tags() {
  jq -r --arg re "^${VERSION_RE_BODY}$" \
    '.[] | select(.prerelease == true and .draft == false
                  and (.published_at != null)
                  and (.tag_name | test("-next") | not)
                  and (.tag_name | sub("^v";"") | test($re)))
         | "\(.published_at)\t\(.tag_name | sub("^v";""))"' "$(listing "$1")"
}

stable_tags() {
  jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name' "$(listing "$1")" \
    | sed 's/^v//' | { grep -E "$STABLE_RE" || true; }
}

# The most recently published pre-release whose final release is not out yet.
# /releases is not returned in any dependable order, so publish time is read
# from the payload and sorted here rather than trusting the first row.
newest_unreleased_pre_release() {
  local repo="$1" released
  released="$(stable_tags "$repo")"
  local ranked first
  ranked="$(pre_release_tags "$repo" | while IFS=$'\t' read -r published version; do
    [ -n "$version" ] || continue
    if grep -qxF "${version%%-*}" <<<"$released"; then continue; fi
    printf '%s\t%s\t%s\n' "$published" "$(sort_key "$version")" "$version"
  done | sort -t "$(printf '\t')" -k1,1r -k2,2Vr)"
  [ -n "$ranked" ] || return 0
  first="${ranked%%$'\n'*}"
  printf '%s' "${first##*$'\t'}"
}

# Highest release below the target. Anything below the target that is not on the
# target's own line is also below that line, so no line filter is needed.
base_for_target() {
  local target="$1" candidate
  stable_tags "$2" | while read -r candidate; do
    [ -n "$candidate" ] || continue
    if is_below "$candidate" "$target"; then printf '%s\n' "$candidate"; fi
  done | highest_of
}

load_listing vcluster

UP="${STANDALONE_VCLUSTER_UPGRADE_VERSION_INPUT:-}"
UP="${UP#v}"
if [ -z "$UP" ]; then
  UP="$(newest_unreleased_pre_release vcluster)"
  [ -n "$UP" ] || { echo "no vCluster pre-release found in loft-sh/vcluster"; exit 1; }
  echo "Resolved newest unreleased vCluster pre-release: $UP"
fi
[[ "$UP" =~ $VERSION_RE ]] || { echo "invalid standalone-vcluster-upgrade-version: $UP"; exit 1; }

VERSION="${STANDALONE_VCLUSTER_VERSION_INPUT:-}"
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
  VERSION="$(base_for_target "$UP" vcluster)"
  [ -n "$VERSION" ] || { echo "no stable vCluster release below $UP"; exit 1; }
  echo "Resolved vCluster base below $UP: $VERSION"
fi
[[ "$VERSION" =~ $VERSION_RE ]] || { echo "invalid standalone-vcluster-version: $VERSION"; exit 1; }
[ "$UP" != "$VERSION" ] || { echo "standalone-vcluster-upgrade-version must differ from base ($VERSION)"; exit 1; }
is_below "$VERSION" "$UP" \
  || { echo "standalone-vcluster-upgrade-version ($UP) is not newer than base ($VERSION)"; exit 1; }

load_listing loft-enterprise

RC="${PLATFORM_RC_VERSION_INPUT:-}"
RC="${RC#v}"
if [ -z "$RC" ]; then
  RC="$(newest_unreleased_pre_release loft-enterprise)"
  [ -n "$RC" ] || { echo "no platform pre-release found in loft-sh/loft-enterprise"; exit 1; }
  echo "Resolved newest unreleased platform pre-release: $RC"
fi
[[ "$RC" =~ $VERSION_RE ]] || { echo "invalid platform-rc-version: $RC"; exit 1; }

BASE="${PLATFORM_BASE_VERSION_INPUT:-}"
BASE="${BASE#v}"
if [ -z "$BASE" ]; then
  BASE="$(base_for_target "$RC" loft-enterprise)"
  [ -n "$BASE" ] || { echo "no stable platform release below $RC"; exit 1; }
  echo "Resolved platform base below $RC: $BASE"
fi
[[ "$BASE" =~ $VERSION_RE ]] || { echo "invalid platform-base-version: $BASE"; exit 1; }
[ "$BASE" != "$RC" ] || { echo "platform-base-version must differ from platform-rc-version"; exit 1; }
is_below "$BASE" "$RC" \
  || { echo "platform-rc-version ($RC) is not newer than platform-base-version ($BASE)"; exit 1; }

{
  echo "standalone-vcluster-version=$VERSION"
  echo "standalone-vcluster-upgrade-version=$UP"
  echo "platform-rc-version=$RC"
  echo "platform-base-version=$BASE"
} >> "$GITHUB_OUTPUT"

# DEFAULT_VCLUSTER_CHART_VERSION is the name the helm-chart-install path wants.
{
  echo "STANDALONE_VCLUSTER_VERSION=$VERSION"
  echo "STANDALONE_VCLUSTER_UPGRADE_VERSION=$UP"
  echo "PLATFORM_BASE_VERSION=$BASE"
  echo "PLATFORM_RC_VERSION=$RC"
  echo "DEFAULT_VCLUSTER_CHART_VERSION=$VERSION"
} >> "$GITHUB_ENV"

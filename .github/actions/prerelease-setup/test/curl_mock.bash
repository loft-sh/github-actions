#!/usr/bin/env bash
# Stubs `curl` on PATH for resolve-versions.sh tests. Serves paged release
# listings from per-repo, per-page fixtures and records every request so tests
# can assert on how many pages were read.
#
# Fixtures are registered with `set_releases <repo> <page> <json>`; any page
# without a fixture returns "[]", which the script treats as the end of the
# listing.
#
# Knobs:
#   CURL_MOCK_FAIL=1        force a non-zero exit on every call.
#   CURL_MOCK_BODY=<text>   return this body with a 0 exit, to simulate a 200
#                           response that is not a JSON array.
#   CURL_MOCK_FAIL_AFTER=N  succeed for N calls, then fail, to exercise a
#                           failure part-way through reading a listing.

setup_curl_mock() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  PATH="$MOCK_DIR:$PATH"
  export PATH

  export CURL_MOCK_CALLS="$MOCK_DIR/calls.log"
  export CURL_MOCK_FIXTURES="$MOCK_DIR/fixtures"
  : > "$CURL_MOCK_CALLS"
  mkdir -p "$CURL_MOCK_FIXTURES"

  cat > "$MOCK_DIR/curl" <<'EOF'
#!/usr/bin/env bash
# Mock curl. Only understands the release-listing URL the script builds.
url=""
for arg in "$@"; do
  case "$arg" in https://*|http://*) url="$arg" ;; esac
done
printf '%s\n' "$url" >> "$CURL_MOCK_CALLS"

if [ -n "${CURL_MOCK_BODY:-}" ]; then
  printf '%s' "$CURL_MOCK_BODY"
  exit 0
fi
if [ "${CURL_MOCK_FAIL:-0}" = "1" ]; then
  echo "mock curl: forced failure" >&2
  exit 22
fi
if [ -n "${CURL_MOCK_FAIL_AFTER:-}" ] && [ "$(wc -l < "$CURL_MOCK_CALLS")" -gt "$CURL_MOCK_FAIL_AFTER" ]; then
  echo "mock curl: forced failure after $CURL_MOCK_FAIL_AFTER call(s)" >&2
  exit 22
fi

repo="${url#*/repos/loft-sh/}"; repo="${repo%%/releases*}"
page="${url##*&page=}"
fixture="$CURL_MOCK_FIXTURES/${repo}-${page}.json"
if [ -f "$fixture" ]; then cat "$fixture"; else printf '[]'; fi
EOF
  chmod +x "$MOCK_DIR/curl"
}

teardown_curl_mock() {
  rm -rf "$MOCK_DIR"
}

# set_releases <repo> <page> <json-array>
set_releases() {
  printf '%s' "$3" > "$CURL_MOCK_FIXTURES/$1-$2.json"
}

# release <tag> <prerelease> [published_at] -> one JSON object
release() {
  printf '{"tag_name":"%s","prerelease":%s,"draft":false,"published_at":"%s"}' \
    "$1" "$2" "${3:-2026-01-01T00:00:00Z}"
}

# filler <count> -> N throwaway stable releases, to pad a page to 100 entries
# so the "a short page is the last page" rule behaves as it does against the API
filler() {
  local n="$1" i out=""
  for ((i = 0; i < n; i++)); do
    out="${out},$(release "v0.0.${i}" false 2020-01-01T00:00:00Z)"
  done
  printf '%s' "${out#,}"
}

# pages_read <repo>
pages_read() {
  grep -c "/repos/loft-sh/$1/releases" "$CURL_MOCK_CALLS" || true
}

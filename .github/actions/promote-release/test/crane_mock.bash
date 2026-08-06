#!/usr/bin/env bash
# Stub `crane` on PATH for action.sh tests. Covers the two crane subcommands
# the action uses:
#
#   crane tag <src> <newtag>   the digest-preserving retag. Records
#                              "CREATE <dest> <src>" into $CRANE_MOCK_CALLS,
#                              where <dest> is <src-repo>:<newtag> (crane tag
#                              applies <newtag> in <src>'s own repo). Fails if
#                              CRANE_MOCK_FAIL=1. The CREATE marker is kept
#                              (rather than TAG) so the retag assertions read
#                              as "dest was retagged from src", independent of
#                              which CLI performs it.
#   crane digest <ref>         the pre-flight existence check. Records
#                              "INSPECT <ref>"; exits 1 if <ref> is listed in
#                              space-separated $CRANE_MOCK_MISSING, else 0.
#
#                              An absent tag emits crane's OWN wording, captured
#                              live from crane v0.20.2 (the version action.yml
#                              pins) against ghcr.io - NOT the registry's
#                              MANIFEST_UNKNOWN JSON, which crane never
#                              surfaces. Getting this wrong is how a suite can
#                              cover a classifier that does not match reality.
#
#                              $CRANE_MOCK_DIGEST_ERROR fails EVERY digest call
#                              with that message - the not-absence class (a
#                              refused token exchange, a rate limit, DNS), which
#                              must never be reported as a missing manifest.
#
#                              CRANE_MOCK_DIGEST_ERROR_<sanitized ref> does the
#                              same for one ref only, so a mixed run - one source
#                              genuinely absent, a sibling merely unreadable - can
#                              be expressed. That mix is the only case where the
#                              per-entry classification does work a single
#                              run-wide verdict could not. Set it with
#                              set_digest_error, which sanitizes the ref the same
#                              way gh_mock.bash's mock keys its per-repo lookups.

setup_crane_mock() {
  CRANE_MOCK_DIR="$(mktemp -d)"
  export CRANE_MOCK_DIR
  PATH="$CRANE_MOCK_DIR:$PATH"
  export PATH

  export CRANE_MOCK_CALLS="$CRANE_MOCK_DIR/calls.log"
  : > "$CRANE_MOCK_CALLS"
  export CRANE_MOCK_MISSING="${CRANE_MOCK_MISSING:-}"

  cat > "$CRANE_MOCK_DIR/crane" <<'EOF'
#!/usr/bin/env bash
# Mock crane. See crane_mock.bash for the full contract.

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

verb="${1:-}"
shift || true

case "$verb" in
  tag)
    src="$1"
    newtag="$2"
    # crane tag applies <newtag> in <src>'s repository -> dest is the repo of
    # <src> (everything up to the last ':') with the new tag.
    dest="${src%:*}:${newtag}"
    printf 'CREATE %s %s\n' "$dest" "$src" >> "$CRANE_MOCK_CALLS"
    if [ "${CRANE_MOCK_FAIL:-0}" = "1" ]; then
      echo "mock crane: forced failure" >&2
      exit 1
    fi
    exit 0
    ;;
  digest)
    ref="$1"
    printf 'INSPECT %s\n' "$ref" >> "$CRANE_MOCK_CALLS"
    if [ -n "${CRANE_MOCK_DIGEST_ERROR:-}" ]; then
      echo "$CRANE_MOCK_DIGEST_ERROR" >&2
      exit 1
    fi
    # Per-ref override, checked before the missing list so a single ref can be
    # made unreadable while another stays genuinely absent. Same dynamic-variable
    # convention as gh_mock.bash's per-repo overrides.
    per_ref="CRANE_MOCK_DIGEST_ERROR_$(sanitize "$ref")"
    if [ -n "${!per_ref:-}" ]; then
      echo "${!per_ref}" >&2
      exit 1
    fi
    for missing in $CRANE_MOCK_MISSING; do
      if [ "$missing" = "$ref" ]; then
        # crane's real absent-tag wording (v0.20.2, live against ghcr.io). It
        # renders the HTTP status itself; the registry's MANIFEST_UNKNOWN never
        # reaches stderr.
        repo="${ref%:*}"; tag="${ref##*:}"
        registry="${repo%%/*}"; path="${repo#*/}"
        echo "$(date '+%Y/%m/%d %H:%M:%S') HEAD request failed, falling back on GET: HEAD https://${registry}/v2/${path}/manifests/${tag}: unexpected status code 404 Not Found (HEAD responses have no body, use GET for details)" >&2
        exit 1
      fi
    done
    exit 0
    ;;
  *)
    echo "unsupported crane invocation: $verb $*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$CRANE_MOCK_DIR/crane"
}

# Makes `crane digest <ref>` fail with <message> for that ref only, mirroring
# action.bats's set_release_list/set_checksums_fixture helpers. Kept here rather
# than beside those, so the setter sits with the contract it drives.
set_digest_error() {
  local ref="$1" message="$2" varname
  varname="CRANE_MOCK_DIGEST_ERROR_$(printf '%s' "$ref" | tr -c 'A-Za-z0-9' '_')"
  export "$varname=$message"
}

teardown_crane_mock() {
  rm -rf "$CRANE_MOCK_DIR"
}

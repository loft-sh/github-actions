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
# Mock crane. Covers `crane tag` and `crane digest`.
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
    for missing in $CRANE_MOCK_MISSING; do
      [ "$missing" = "$ref" ] && exit 1
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

teardown_crane_mock() {
  rm -rf "$CRANE_MOCK_DIR"
}

#!/usr/bin/env bash
# Stub `docker` on PATH for action.sh tests. Covers
# `docker buildx imagetools create --tag <dest> <src>` (records "CREATE
# <dest> <src>" into $DOCKER_MOCK_CALLS, fails if DOCKER_MOCK_FAIL=1) and
# `docker buildx imagetools inspect <ref>` (records "INSPECT <ref>"; exits 1
# if <ref> is listed in space-separated $DOCKER_MOCK_MISSING, 0 otherwise).

setup_docker_mock() {
  DOCKER_MOCK_DIR="$(mktemp -d)"
  export DOCKER_MOCK_DIR
  PATH="$DOCKER_MOCK_DIR:$PATH"
  export PATH

  export DOCKER_MOCK_CALLS="$DOCKER_MOCK_DIR/calls.log"
  : > "$DOCKER_MOCK_CALLS"
  export DOCKER_MOCK_MISSING="${DOCKER_MOCK_MISSING:-}"

  cat > "$DOCKER_MOCK_DIR/docker" <<'EOF'
#!/usr/bin/env bash
# Mock docker. Covers `docker buildx imagetools create` and `... inspect`.

[ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] || {
  echo "unsupported docker invocation: $*" >&2
  exit 99
}
verb="${3:-}"
shift 3

case "$verb" in
  create)
    dest=""
    src=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --tag) dest="$2"; shift 2 ;;
        *)     src="$1"; shift ;;
      esac
    done
    printf 'CREATE %s %s\n' "$dest" "$src" >> "$DOCKER_MOCK_CALLS"
    if [ "${DOCKER_MOCK_FAIL:-0}" = "1" ]; then
      echo "mock docker: forced failure" >&2
      exit 1
    fi
    exit 0
    ;;
  inspect)
    ref="$1"
    printf 'INSPECT %s\n' "$ref" >> "$DOCKER_MOCK_CALLS"
    for missing in $DOCKER_MOCK_MISSING; do
      [ "$missing" = "$ref" ] && exit 1
    done
    exit 0
    ;;
  *)
    echo "unsupported docker buildx imagetools verb: $verb" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$DOCKER_MOCK_DIR/docker"
}

teardown_docker_mock() {
  rm -rf "$DOCKER_MOCK_DIR"
}

#!/usr/bin/env bash
# Stub `docker` on PATH for action.sh tests. Only covers
# `docker buildx imagetools create --tag <dest> <src>`, which is the only
# docker invocation action.sh makes. Records each call (one line per call:
# "CREATE <dest> <src>") into $DOCKER_MOCK_CALLS and returns success unless
# DOCKER_MOCK_FAIL=1.

setup_docker_mock() {
  DOCKER_MOCK_DIR="$(mktemp -d)"
  export DOCKER_MOCK_DIR
  PATH="$DOCKER_MOCK_DIR:$PATH"
  export PATH

  export DOCKER_MOCK_CALLS="$DOCKER_MOCK_DIR/calls.log"
  : > "$DOCKER_MOCK_CALLS"

  cat > "$DOCKER_MOCK_DIR/docker" <<'EOF'
#!/usr/bin/env bash
# Mock docker. Only covers `docker buildx imagetools create --tag <dest> <src>`.

[ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "create" ] || {
  echo "unsupported docker invocation: $*" >&2
  exit 99
}
shift 3

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
EOF
  chmod +x "$DOCKER_MOCK_DIR/docker"
}

teardown_docker_mock() {
  rm -rf "$DOCKER_MOCK_DIR"
}

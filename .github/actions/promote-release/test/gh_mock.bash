#!/usr/bin/env bash
# Stub `gh` on PATH for action.sh tests. Covers `gh release view <tag> --repo
# <repo>`, `gh release edit <tag> --repo <repo> [flags]`, and `gh release
# list --repo <repo> --json ... --limit ...`. Records every invocation (one
# line per call) into $GH_MOCK_CALLS.
#
# `gh release view` exits 0 only for tag/repo pairs listed in
# $GH_MOCK_KNOWN_RELEASES (space-separated "repo:tag" entries), 1 otherwise --
# lets tests simulate a missing paired release. `gh release edit` always
# succeeds unless GH_MOCK_FAIL=1. `gh release list` prints the JSON array
# from GH_MOCK_RELEASE_LIST_<repo, non-alnum -> _> (default "[]"), so each
# repo can be given its own release history in a test; it exits 1 (API
# failure, not "no releases") when GH_MOCK_LIST_FAIL=1.

setup_gh_mock() {
  GH_MOCK_DIR="$(mktemp -d)"
  export GH_MOCK_DIR
  PATH="$GH_MOCK_DIR:$PATH"
  export PATH

  export GH_MOCK_CALLS="$GH_MOCK_DIR/calls.log"
  : > "$GH_MOCK_CALLS"
  export GH_MOCK_KNOWN_RELEASES="${GH_MOCK_KNOWN_RELEASES:-}"

  cat > "$GH_MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh. Only covers `gh release view`, `gh release edit`, `gh release list`.

subcommand="${1:-}"
action="${2:-}"
[ "$subcommand" = "release" ] || { echo "unsupported gh invocation: $*" >&2; exit 99; }
shift 2

tag=""
repo=""
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  repo="$2"; shift 2 ;;
    --json)  shift 2 ;;
    --limit) shift 2 ;;
    -*)      extra+=("$1"); shift ;;
    *)       tag="$1"; shift ;;
  esac
done

case "$action" in
  view)
    printf 'VIEW %s %s\n' "$repo" "$tag" >> "$GH_MOCK_CALLS"
    for known in $GH_MOCK_KNOWN_RELEASES; do
      [ "$known" = "${repo}:${tag}" ] && exit 0
    done
    exit 1
    ;;
  edit)
    printf 'EDIT %s %s %s\n' "$repo" "$tag" "${extra[*]}" >> "$GH_MOCK_CALLS"
    if [ "${GH_MOCK_FAIL:-0}" = "1" ]; then
      echo "mock gh: forced failure" >&2
      exit 1
    fi
    exit 0
    ;;
  list)
    printf 'LIST %s\n' "$repo" >> "$GH_MOCK_CALLS"
    if [ "${GH_MOCK_LIST_FAIL:-0}" = "1" ]; then
      echo "mock gh: forced release list failure" >&2
      exit 1
    fi
    varname="GH_MOCK_RELEASE_LIST_$(printf '%s' "$repo" | tr -c 'A-Za-z0-9' '_')"
    printf '%s\n' "${!varname:-[]}"
    exit 0
    ;;
  *)
    echo "unsupported gh release subcommand: $action" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$GH_MOCK_DIR/gh"
}

teardown_gh_mock() {
  rm -rf "$GH_MOCK_DIR"
}

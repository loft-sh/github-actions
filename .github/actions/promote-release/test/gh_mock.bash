#!/usr/bin/env bash
# Stub `gh` on PATH for action.sh tests. Covers:
#   gh release view/edit/list/download   (release subcommands)
#   gh api [-X METHOD] PATH [-f k=v ...] (contents API, for Homebrew)
# Records every invocation (one line per call) into $GH_MOCK_CALLS.
#
# release view  - exits 0 only for tag/repo pairs listed in
#                 $GH_MOCK_KNOWN_RELEASES (space-separated "repo:tag"), 1
#                 otherwise.
# release edit  - always succeeds unless GH_MOCK_FAIL=1.
# release list  - prints the JSON array from
#                 GH_MOCK_RELEASE_LIST_<repo, non-alnum -> _> (default "[]");
#                 exits 1 (API failure, not "no releases") if
#                 GH_MOCK_LIST_FAIL=1.
# release download - copies the file at GH_MOCK_CHECKSUMS_<repo, sanitized>
#                 (a real path a test points at) to the -O destination;
#                 exits 1 if GH_MOCK_DOWNLOAD_FAIL=1.
# api GET  repos/R/contents/P - returns {"sha":..., "content": <base64>}
#                 sourced from GH_MOCK_CONTENTS_FILE_<R/P, sanitized> (a real
#                 file path) and GH_MOCK_CONTENTS_SHA_<...> (default
#                 "fakesha"); exits 1 if GH_MOCK_CONTENTS_GET_FAIL=1.
# api PUT  repos/R/contents/P - decodes the `content` -f field and writes it
#                 to $GH_MOCK_DIR/put_<R/P, sanitized>.out so a test can
#                 inspect exactly what would have been committed; exits 1 if
#                 GH_MOCK_API_PUT_FAIL=1.

setup_gh_mock() {
  GH_MOCK_DIR="$(mktemp -d)"
  export GH_MOCK_DIR
  PATH="$GH_MOCK_DIR:$PATH"
  export PATH

  export GH_MOCK_CALLS="$GH_MOCK_DIR/calls.log"
  : > "$GH_MOCK_CALLS"
  export GH_MOCK_KNOWN_RELEASES="${GH_MOCK_KNOWN_RELEASES:-}"

  cat > "$GH_MOCK_DIR/gh" <<'MOCKEOF'
#!/usr/bin/env bash
# Mock gh. See gh_mock.bash for the full contract.

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

subcommand="${1:-}"
shift || true

if [ "$subcommand" = "release" ]; then
  action="${1:-}"
  shift || true

  tag=""
  repo=""
  extra=()
  pattern=""
  outfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)    repo="$2"; shift 2 ;;
      --json)    shift 2 ;;
      --limit)   shift 2 ;;
      -p)        pattern="$2"; shift 2 ;;
      -O)        outfile="$2"; shift 2 ;;
      -*)        extra+=("$1"); shift ;;
      *)         tag="$1"; shift ;;
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
      varname="GH_MOCK_RELEASE_LIST_$(sanitize "$repo")"
      printf '%s\n' "${!varname:-[]}"
      exit 0
      ;;
    download)
      printf 'DOWNLOAD %s %s %s\n' "$repo" "$tag" "$pattern" >> "$GH_MOCK_CALLS"
      if [ "${GH_MOCK_DOWNLOAD_FAIL:-0}" = "1" ]; then
        echo "mock gh: forced download failure" >&2
        exit 1
      fi
      varname="GH_MOCK_CHECKSUMS_$(sanitize "$repo")"
      src="${!varname:-}"
      if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "mock gh: no checksums fixture for $repo (set GH_MOCK_CHECKSUMS_$(sanitize "$repo"))" >&2
        exit 1
      fi
      cp "$src" "$outfile"
      exit 0
      ;;
    *)
      echo "unsupported gh release subcommand: $action" >&2
      exit 99
      ;;
  esac
fi

if [ "$subcommand" = "api" ]; then
  method="GET"
  path=""
  msg=""
  content=""
  put_sha=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X)
        method="$2"; shift 2 ;;
      -f)
        case "$2" in
          message=*) msg="${2#message=}" ;;
          content=*) content="${2#content=}" ;;
          sha=*)     put_sha="${2#sha=}" ;;
        esac
        shift 2
        ;;
      --jq) shift 2 ;;
      -*)   shift ;;
      *)    path="$1"; shift ;;
    esac
  done

  case "$method" in
    GET)
      printf 'API GET %s\n' "$path" >> "$GH_MOCK_CALLS"
      if [ "${GH_MOCK_CONTENTS_GET_FAIL:-0}" = "1" ]; then
        echo "mock gh: forced contents GET failure" >&2
        exit 1
      fi
      varname="GH_MOCK_CONTENTS_FILE_$(sanitize "$path")"
      src="${!varname:-}"
      if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "mock gh: no contents fixture for $path (set GH_MOCK_CONTENTS_FILE_$(sanitize "$path"))" >&2
        exit 1
      fi
      shavar="GH_MOCK_CONTENTS_SHA_$(sanitize "$path")"
      sha="${!shavar:-fakesha}"
      b64=$(base64 -w0 "$src")
      printf '{"sha":"%s","content":"%s"}\n' "$sha" "$b64"
      exit 0
      ;;
    PUT)
      printf 'API PUT %s sha=%s\n' "$path" "$put_sha" >> "$GH_MOCK_CALLS"
      if [ "${GH_MOCK_API_PUT_FAIL:-0}" = "1" ]; then
        echo "mock gh: forced contents PUT failure" >&2
        exit 1
      fi
      out="$GH_MOCK_DIR/put_$(sanitize "$path").out"
      printf '%s' "$content" | base64 -d > "$out"
      : "$msg"
      exit 0
      ;;
    *)
      echo "unsupported gh api method: $method" >&2
      exit 99
      ;;
  esac
fi

echo "unsupported gh invocation: $subcommand $*" >&2
exit 99
MOCKEOF
  chmod +x "$GH_MOCK_DIR/gh"
}

teardown_gh_mock() {
  rm -rf "$GH_MOCK_DIR"
}

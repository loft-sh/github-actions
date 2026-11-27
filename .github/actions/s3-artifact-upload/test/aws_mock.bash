#!/usr/bin/env bash
# Stub `aws` on PATH for upload.sh tests. Every call is appended to $AWS_MOCK_CALLS, and `aws s3 cp <file> s3://...`
# copies the file to $AWS_MOCK_STORE/<bucket>/<key>, so tests can read what was uploaded.
#
# AWS_MOCK_HEAD     head-object answer: exists, denied (a 403), or by default whether the key is in the store
# AWS_MOCK_CP_FAIL  fail the cp of a key ending in this suffix

setup_aws_mock() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="$MOCK_DIR/bin:$PATH"
  export AWS_MOCK_CALLS="$MOCK_DIR/calls.log"
  export AWS_MOCK_STORE="$MOCK_DIR/store"
  mkdir -p "$MOCK_DIR/bin" "$AWS_MOCK_STORE"
  : >"$AWS_MOCK_CALLS"

  cat >"$MOCK_DIR/bin/aws" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >>"$AWS_MOCK_CALLS"
case "$1 $2" in
"s3api head-object")
  bucket=${*: -3:1}
  key=${*: -1}
  head=${AWS_MOCK_HEAD:-}
  [[ -n $head || ! -f $AWS_MOCK_STORE/$bucket/$key ]] || head=exists
  case "$head" in
  exists) echo '{"ContentLength": 1}' ;;
  denied) echo "An error occurred (403) when calling the HeadObject operation: Forbidden" >&2; exit 254 ;;
  *) echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254 ;;
  esac
  ;;
"s3 cp")
  src=${*: -2:1}
  dst=${*: -1}
  if [[ -n ${AWS_MOCK_CP_FAIL:-} && $dst == *"$AWS_MOCK_CP_FAIL" ]]; then
    echo "upload failed: $dst" >&2
    exit 1
  fi
  key=${dst#s3://}
  mkdir -p "$AWS_MOCK_STORE/$(dirname "$key")"
  cp "$src" "$AWS_MOCK_STORE/$key"
  ;;
*)
  echo "unsupported aws invocation: $*" >&2
  exit 99
  ;;
esac
MOCK
  chmod +x "$MOCK_DIR/bin/aws"
}

teardown_aws_mock() {
  rm -rf "$MOCK_DIR"
}

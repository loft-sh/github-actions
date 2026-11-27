#!/usr/bin/env bash
# Uploads files to s3://<bucket>/<prefix>/<name>, then a sha256 manifest of them. The manifest goes last and marks
# the prefix as released: a prefix that has one is refused, one left without it by a failed run is overwritten. Its
# name is fixed, so a caller cannot release a prefix again under another name.
set -euo pipefail

bucket=${INPUT_BUCKET:?INPUT_BUCKET is required}
prefix=${INPUT_PREFIX:?INPUT_PREFIX is required}
manifest=SHA256SUMS
: "${INPUT_FILES:?INPUT_FILES is required}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

# In the C locale, so the same name gets the same answer on every runner.
has_control_char() {
  local LC_ALL=C
  [[ $1 == *[[:cntrl:]]* ]]
}

if [[ $prefix == /* || $prefix == */ || $prefix == *//* || $prefix =~ (^|/)\.\.?(/|$) ]]; then
  fail "prefix must be a relative S3 key prefix without leading, trailing or double slashes, . or ..: $prefix"
fi

# Everything is checked before the first upload, so a bad input leaves the bucket untouched.
files=()
declare -A names=()
while read -r file; do
  [[ -n $file ]] || continue
  [[ -f $file ]] || fail "not a file: $file"
  name=${file##*/}
  [[ $name != "$manifest" ]] || fail "$file has the name of the manifest"
  # sha256sum -c reads - as stdin and a trailing CR as part of the line end.
  if [[ $name == - ]] || has_control_char "$name"; then
    fail "$file cannot be listed in the manifest: its name is - or has a control character"
  fi
  [[ -z ${names[$name]:-} ]] || fail "$file and ${names[$name]} would both upload as $name"
  names[$name]=$file
  files+=("$file")
done <<<"$INPUT_FILES"
((${#files[@]} > 0)) || fail "files lists no file"

dest="s3://$bucket/$prefix"
# A missing object is a 404 only with s3:ListBucket; without it S3 answers 403, which stops the upload here.
if err=$(aws s3api head-object --bucket "$bucket" --key "$prefix/$manifest" 2>&1 >/dev/null); then
  fail "$dest/$manifest exists: $prefix is already released"
fi
[[ $err == *"(404)"* ]] || fail "cannot check $dest/$manifest: $err"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for file in "${files[@]}"; do
  # From stdin: sha256sum puts a backslash before the sum of a name it escapes.
  sum=$(sha256sum <"$file" | cut -d' ' -f1)
  echo "uploading $file to $dest/${file##*/}"
  aws s3 cp --only-show-errors --metadata "sha256=$sum" "$file" "$dest/${file##*/}"
  printf '%s  %s\n' "$sum" "${file##*/}" >>"$work/$manifest"
done
aws s3 cp --only-show-errors "$work/$manifest" "$dest/$manifest"
cat "$work/$manifest"

echo "manifest-url=$dest/$manifest" >>"$GITHUB_OUTPUT"

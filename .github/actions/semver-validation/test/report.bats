#!/usr/bin/env bats
# Tests for semver-validation/src/report.sh
#
# semstat is stubbed with a per-subcommand script whose stdout, stderr and exit
# code the test sets, so every branch here can be reached without pinning a real
# release. semstat's own suite is what proves its answers.

SCRIPT="$BATS_TEST_DIRNAME/../src/report.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  export TEST_DIR

  export GITHUB_OUTPUT="$TEST_DIR/github_output"
  : >"$GITHUB_OUTPUT"

  export STUB_DIR="$TEST_DIR/stub"
  mkdir -p "$STUB_DIR"

  export SEMSTAT_BIN="$TEST_DIR/semstat"
  cat >"$SEMSTAT_BIN" <<'MOCK'
#!/usr/bin/env bash
command="$1"
shift
printf '%s\n' "$*" >>"$STUB_DIR/${command}.args"
[ -f "$STUB_DIR/${command}.out" ] && cat "$STUB_DIR/${command}.out"
[ -f "$STUB_DIR/${command}.err" ] && cat "$STUB_DIR/${command}.err" >&2
exit "$(cat "$STUB_DIR/${command}.exit" 2>/dev/null || echo 0)"
MOCK
  chmod +x "$SEMSTAT_BIN"

  unset INPUT_COMPARE_TO
}

teardown() {
  rm -rf "$TEST_DIR"
}

# stub <command> <exit> [stdout] [stderr]
stub() {
  echo "$2" >"$STUB_DIR/$1.exit"
  printf '%s' "${3-}" >"$STUB_DIR/$1.out"
  printf '%s' "${4-}" >"$STUB_DIR/$1.err"
}

# A version semstat reads happily, with every field set.
stub_valid() {
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":"rc.3","build":null,"raw":"v2.1.0-rc.3"}
'
  stub type 0 'rc
'
}

# Reads one output back out of the heredoc framing report.sh writes.
output_value() {
  awk -v key="$1" '
    !inside && index($0, key "<<") == 1 {
      delim = substr($0, length(key) + 3)
      inside = 1
      first = 1
      next
    }
    inside && $0 == delim { inside = 0; next }
    inside { printf "%s%s", (first ? "" : "\n"), $0; first = 0 }
  ' "$GITHUB_OUTPUT"
}

# The keys written, so a test can assert an output was written at all rather
# than only that it reads back empty.
output_keys() {
  grep -oE '^[a-z_]+<<' "$GITHUB_OUTPUT" | sed 's/<<$//'
}

@test "a valid version reports its parts, type and stability" {
  export INPUT_VERSION=v2.1.0-rc.3
  stub_valid

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "true" ]
  [ "$(output_value error_message)" = "" ]
  [ "$(output_value parsed_version)" = '{"major":2,"minor":1,"patch":0,"prerelease":"rc.3","build":null,"raw":"v2.1.0-rc.3"}' ]
  [ "$(output_value major)" = "2" ]
  [ "$(output_value minor)" = "1" ]
  [ "$(output_value patch)" = "0" ]
  [ "$(output_value prerelease)" = "rc.3" ]
  [ "$(output_value build)" = "" ]
  [ "$(output_value is_stable)" = "false" ]
  [ "$(output_value release_type)" = "rc" ]
}

@test "a stable version reports is_stable true and an empty prerelease" {
  export INPUT_VERSION=v2.1.0
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_stable)" = "true" ]
  [ "$(output_value prerelease)" = "" ]
  [ "$(output_value release_type)" = "stable" ]
}

@test "build metadata is reported without its leading plus" {
  export INPUT_VERSION=1.0.0+build.5
  stub parse 0 '{"major":1,"minor":0,"patch":0,"prerelease":null,"build":"build.5","raw":"1.0.0+build.5"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$(output_value build)" = "build.5" ]
}

@test "an invalid version stays green and keeps the message the node action used" {
  export INPUT_VERSION=1.2
  stub parse 2 '' 'semstat: "1.2" is not a valid semantic version: invalid semantic version
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "false" ]
  [ "$(output_value parsed_version)" = "" ]
  [ "$(output_value error_message)" = "Invalid semver format: '1.2'" ]
  [[ "$output" == *"::warning::"* ]]
}

@test "an invalid version leaves every detail output empty rather than unwritten" {
  export INPUT_VERSION=nope
  export INPUT_COMPARE_TO=v1.0.0
  stub parse 2 '' 'semstat: bad
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  for key in is_stable release_type major minor patch prerelease build comparison is_greater; do
    [ "$(output_value "$key")" = "" ]
    output_keys | grep -qx "$key"
  done
}

@test "a valid version with an unroutable suffix keeps is_valid true" {
  export INPUT_VERSION=v1.11.1-kubernetes.115
  stub parse 0 '{"major":1,"minor":11,"patch":1,"prerelease":"kubernetes.115","build":null,"raw":"v1.11.1-kubernetes.115"}
'
  stub type 2 '' 'semstat: version "v1.11.1-kubernetes.115" has an unsupported prerelease suffix
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "true" ]
  [ "$(output_value release_type)" = "" ]
  [ "$(output_value is_stable)" = "false" ]
  [[ "$output" == *"unsupported prerelease suffix"* ]]
  # No annotation: a valid version this pipeline does not route is an ordinary
  # answer, and a caller reading only is_valid has nothing to act on.
  [[ "$output" != *"::warning::"* ]]
}

@test "a missing version fails the step, as the node action did" {
  export INPUT_VERSION=""

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [ "$(output_value is_valid)" = "false" ]
  [ "$(output_value error_message)" = "Input required and not supplied: version" ]
  [[ "$output" == *"::error::"* ]]
}

@test "no compare_to leaves the comparison outputs empty and calls neither compare nor validate" {
  export INPUT_VERSION=v2.1.0-rc.3
  stub_valid

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value comparison)" = "" ]
  [ "$(output_value is_greater)" = "" ]
  [ ! -f "$STUB_DIR/compare.args" ]
  [ ! -f "$STUB_DIR/validate.args" ]
}

@test "compare_to orders the two versions" {
  export INPUT_VERSION=v2.1.0
  export INPUT_COMPARE_TO=v2.0.9
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'
  stub validate 0
  stub compare 0 '1
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value comparison)" = "1" ]
  [ "$(output_value is_greater)" = "true" ]
  [ "$(cat "$STUB_DIR/compare.args")" = "v2.1.0 v2.0.9" ]
}

@test "an equal comparison is not greater" {
  export INPUT_VERSION=v2.1.0
  export INPUT_COMPARE_TO=v2.1.0+build.1
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'
  stub validate 0
  stub compare 0 '0
'

  run "$SCRIPT"

  [ "$(output_value comparison)" = "0" ]
  [ "$(output_value is_greater)" = "false" ]
}

@test "a lower comparison is not greater" {
  export INPUT_VERSION=v2.0.0-rc.2
  export INPUT_COMPARE_TO=v2.0.0
  stub parse 0 '{"major":2,"minor":0,"patch":0,"prerelease":"rc.2","build":null,"raw":"v2.0.0-rc.2"}
'
  stub type 0 'rc
'
  stub validate 0
  stub compare 0 '-1
'

  run "$SCRIPT"

  [ "$(output_value comparison)" = "-1" ]
  [ "$(output_value is_greater)" = "false" ]
}

@test "an invalid compare_to warns and leaves the comparison empty without ordering anything" {
  export INPUT_VERSION=v2.1.0
  export INPUT_COMPARE_TO=nonsense
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'
  stub validate 1 '' 'semstat: "nonsense" is not a valid semantic version
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "true" ]
  [ "$(output_value comparison)" = "" ]
  [ "$(output_value is_greater)" = "" ]
  [ ! -f "$STUB_DIR/compare.args" ]
  [[ "$output" == *"::warning::compare_to:"* ]]
}

@test "a crashing semstat fails the step instead of calling the version invalid" {
  export INPUT_VERSION=v2.1.0
  stub parse 127 '' 'bash: semstat: No such file or directory
'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::semstat parse exited 127"* ]]
  [ "$(output_value is_valid)" != "false" ]
}

@test "a crashing type fails the step instead of reporting no release type" {
  export INPUT_VERSION=v2.1.0
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 139 '' 'segmentation fault
'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::semstat type exited 139"* ]]
}

@test "a compare that cannot answer for two validated versions fails the step" {
  export INPUT_VERSION=v2.1.0
  export INPUT_COMPARE_TO=v2.0.9
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'
  stub validate 0
  stub compare 2 '' 'semstat: unreadable
'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::semstat compare exited 2"* ]]
}

@test "an omitted compare_to says so, so an empty expression is not silent" {
  export INPUT_VERSION=v2.1.0
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No compare_to given"* ]]
}

@test "a misused command fails the step rather than answering for the version" {
  # semstat exits 64 for misuse, so a subcommand surface that moved under a
  # newer pin is a failure here and not an is_valid=false on a green step.
  export INPUT_VERSION=v2.1.0
  stub parse 64 '' 'semstat: parse takes exactly one version, got 0
'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"semstat parse exited 64"* ]]
  [ "$(output_value is_valid)" != "false" ]
}

@test "a release channel outside the documented vocabulary fails the step" {
  # Callers gate on these strings, so a semstat whose channel names moved has to
  # be a failure rather than a release_type nothing matches.
  export INPUT_VERSION=v2.1.0-rc.3
  stub_valid
  stub type 0 'release-candidate
'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not a release channel this action knows"* ]]
  # Nothing written, so a caller with continue-on-error cannot read this as the
  # valid-but-unroutable case, which writes the same keys and stays green.
  [ -z "$(output_keys)" ]
}

@test "a comparison outside the ordering fails the step" {
  export INPUT_VERSION=v2.1.0-rc.3
  stub_valid
  stub compare 0 'greater
'
  export INPUT_COMPARE_TO=v2.0.0

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not -1, 0 or 1"* ]]
  # Nothing written, for the same reason as the unknown-channel case: a valid
  # version with a compare_to that is not one is green and writes these keys.
  [ -z "$(output_keys)" ]
}

@test "an unwritable GITHUB_OUTPUT fails the step rather than reporting nothing" {
  # Every output would come back empty off a green step otherwise, which the
  # caller cannot tell from a version that had nothing to say.
  export INPUT_VERSION=v2.1.0-rc.3
  stub_valid
  chmod -w "$GITHUB_OUTPUT"

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not write"* ]]
}

@test "a newline in either version cannot forge a command from the plain log lines" {
  # Reaches the echoes on the valid path, which are not warnings and were the
  # ones left unsanitised.
  export INPUT_VERSION='v2.1.0
::error::forged-version'
  export INPUT_COMPARE_TO='v2.0.9
::stop-commands::forged'
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'
  stub validate 0
  stub compare 0 '1
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  ! grep -q '^::error::forged-version' <<<"$output"
  ! grep -q '^::stop-commands::' <<<"$output"
}

@test "a version carrying a newline cannot forge a second output" {
  export INPUT_VERSION='1.2
is_valid=true'
  stub parse 2 '' 'semstat: bad
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "false" ]
  # The newline lands inside the framed error_message rather than starting a line
  # GitHub would read as another output.
  [ "$(output_value error_message)" = "Invalid semver format: '1.2
is_valid=true'" ]
}

@test "a semstat message carrying a newline cannot forge a workflow command" {
  export INPUT_VERSION=1.2
  stub parse 2 '' 'semstat: bad
::error::forged
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  # Folded onto the warning's own line, so nothing reads it as a command.
  ! grep -q '^::error::forged' <<<"$output"
  [[ "$output" == *"::warning::semstat: bad ::error::forged"* ]]
}

@test "a parse output that is not readable JSON fails the step instead of answering" {
  export INPUT_VERSION=v2.1.0-rc.3
  stub parse 0 'semstat: a line ahead of the object
{"major":2,"minor":1,"patch":0,"prerelease":"rc.3","build":null,"raw":"v2.1.0-rc.3"}
'
  stub type 0 'rc
'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::could not read major"* ]]
  # Nothing half-written: an unreadable parse output is the environment broken,
  # not a fact about the version.
  [ -z "$(output_keys)" ]
}

@test "a parse output missing a field fails the step rather than reporting a stable version" {
  export INPUT_VERSION=v2.1.0-rc.3
  # No prerelease key. Unchecked, jq's fallback read this as no prerelease at
  # all, and a release candidate came back is_stable=true on a green step.
  stub parse 0 '{"major":2,"minor":1,"patch":0,"build":null,"raw":"v2.1.0-rc.3"}
'
  stub type 0 'rc
'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::could not read prerelease"* ]]
  [ "$(output_value is_stable)" != "true" ]
}

@test "a parse output whose version numbers are not numbers fails the step" {
  export INPUT_VERSION=v2.1.0
  stub parse 0 '{"major":"2","minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::could not read major"* ]]
}

@test "a dash-leading version is an invalid version rather than a misused semstat" {
  # semstat reads any dash-leading argument as an option and exits 64, which
  # every call here treats as a broken environment. No semver starts with a dash,
  # so this is answered without asking and the step stays green.
  export INPUT_VERSION=-1.2.3

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "false" ]
  [ "$(output_value parsed_version)" = "" ]
  [ "$(output_value error_message)" = "Invalid semver format: '-1.2.3'" ]
  [ ! -f "$STUB_DIR/parse.args" ]
  [[ "$output" == *"::warning::"* ]]
}

@test "a dash-leading version still writes every output" {
  export INPUT_VERSION=--help
  export INPUT_COMPARE_TO=v1.0.0

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  for key in is_valid parsed_version error_message is_stable release_type major \
    minor patch prerelease build comparison is_greater; do
    output_keys | grep -qx "$key"
  done
}

@test "a dash-leading compare_to leaves the comparison empty instead of failing the step" {
  export INPUT_VERSION=v2.1.0
  export INPUT_COMPARE_TO=-2.0.0
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "true" ]
  [ "$(output_value comparison)" = "" ]
  [ "$(output_value is_greater)" = "" ]
  [ ! -f "$STUB_DIR/validate.args" ]
  [ ! -f "$STUB_DIR/compare.args" ]
  [[ "$output" == *"::warning::compare_to:"* ]]
}

@test "surrounding whitespace is trimmed off the version before semstat sees it" {
  # semstat parses a padded version happily and echoes the padding back in raw,
  # so callers putting parsed_version.raw in a tag name would get the padding.
  export INPUT_VERSION="  v2.1.0
"
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "true" ]
  [ "$(head -n1 "$STUB_DIR/parse.args")" = "v2.1.0" ]
  [ "$(head -n1 "$STUB_DIR/type.args")" = "v2.1.0" ]
}

@test "surrounding whitespace is trimmed off compare_to too" {
  export INPUT_VERSION=v2.1.0
  export INPUT_COMPARE_TO="	v2.0.9  "
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'
  stub validate 0
  stub compare 0 '1
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(head -n1 "$STUB_DIR/validate.args")" = "v2.0.9" ]
  [ "$(head -n1 "$STUB_DIR/compare.args")" = "v2.1.0 v2.0.9" ]
  [ "$(output_value comparison)" = "1" ]
}

@test "a BOM-padded version reaches semstat without the BOMs" {
  # getInput trimmed with String.prototype.trim, whose whitespace set includes
  # U+FEFF and U+00A0. [[:space:]] excludes both, so this arrived at semstat with
  # the padding on, came back is_valid=true, and put invisible bytes into
  # parsed_version.raw for any caller reusing raw as a tag name.
  export INPUT_VERSION="$(printf '\xef\xbb\xbfv2.1.0\xef\xbb\xbf')"
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "true" ]
  [ "$(head -n1 "$STUB_DIR/parse.args")" = "v2.1.0" ]
}

@test "a non-breaking-space-padded version reaches semstat without the padding" {
  export INPUT_VERSION="$(printf '\xc2\xa0v2.1.0\xc2\xa0')"
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(head -n1 "$STUB_DIR/parse.args")" = "v2.1.0" ]
}

@test "compare_to is trimmed of the same non-ASCII whitespace as version" {
  # The version path and the compare_to path trim separately; a fix applied to
  # one and not the other leaves compare_to feeding padded input to compare.
  export INPUT_VERSION="$(printf '\xef\xbb\xbfv2.1.0')"
  export INPUT_COMPARE_TO="$(printf '\xc2\xa0v2.0.9\xe3\x80\x80')"
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'
  stub validate 0
  stub compare 0 '1
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(head -n1 "$STUB_DIR/validate.args")" = "v2.0.9" ]
  [ "$(head -n1 "$STUB_DIR/compare.args")" = "v2.1.0 v2.0.9" ]
}

@test "mixed ASCII and Unicode padding is trimmed in one go" {
  # One pass strips at most one of each character from each end, so a version
  # padded with several different ones only comes clean if trim loops.
  export INPUT_VERSION="$(printf '\xef\xbb\xbf \xc2\xa0\tv2.1.0\xe2\x80\xaf \xef\xbb\xbf')"
  stub parse 0 '{"major":2,"minor":1,"patch":0,"prerelease":null,"build":null,"raw":"v2.1.0"}
'
  stub type 0 'stable
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(head -n1 "$STUB_DIR/parse.args")" = "v2.1.0" ]
}

@test "a zero-width space is not whitespace and is left on the version" {
  # U+200B is not in Zs and String.prototype.trim does not remove it, so the node
  # action passed it through and reported the version invalid. Trimming it here
  # would be a different answer than the action being replaced gave.
  export INPUT_VERSION="$(printf '\xe2\x80\x8bv2.1.0')"
  stub parse 2 '' 'semstat: not a semantic version
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "false" ]
  [ "$(head -n1 "$STUB_DIR/parse.args")" = "$(printf '\xe2\x80\x8bv2.1.0')" ]
}

@test "a whitespace-only version is an invalid version, not a missing one" {
  # getInput checked required against the untrimmed value and only then trimmed,
  # so the node action reported this on a green step rather than failing.
  export INPUT_VERSION="   "
  stub parse 2 '' 'semstat: version string is empty
'

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(output_value is_valid)" = "false" ]
  [ "$(output_value error_message)" = "Invalid semver format: ''" ]
}

@test "a temp file that cannot be created fails the step rather than answering wrongly" {
  # An unset stderr_file makes every redirect below fail with status 1, which is
  # inside the set validate uses for "not a version": a good compare_to would
  # come back as one on a green step.
  export INPUT_VERSION=v2.1.0
  export INPUT_COMPARE_TO=v2.0.9
  export TMPDIR="$TEST_DIR/no-such-dir"

  run "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

# A PATH holding bash and the coreutils this script calls, but no jq. Used to
# reach the environment gate without taking jq off the machine running the suite.
path_without_jq() {
  local gate tool
  gate="$(mktemp -d "$TEST_DIR/gate.XXXXXX")"
  for tool in bash head od tr mktemp cat; do
    ln -s "$(command -v "$tool")" "$gate/$tool"
  done
  printf '%s' "$gate"
}

@test "a runner without jq fails the step rather than answering about the version" {
  export INPUT_VERSION=v2.1.0-rc.3
  stub_valid

  run /usr/bin/env "PATH=$(path_without_jq)" "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::jq is required"* ]]
}

@test "a missing version is still reported as missing on a runner without jq" {
  # The two broken things a caller can hand this action are separate answers: a
  # runner without jq is no reason to stop naming the input that never arrived.
  export INPUT_VERSION=""

  run /usr/bin/env "PATH=$(path_without_jq)" "$SCRIPT"

  [ "$status" -eq 1 ]
  [ "$(output_value error_message)" = "Input required and not supplied: version" ]
  [ "$(output_value is_valid)" = "false" ]
  [[ "$output" != *"jq is required"* ]]
}

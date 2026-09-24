#!/usr/bin/env bash
# Shared routing and read-only GitHub probes for the release dispatchers.
#
# Sourced, never run. It sets no shell options and defines no config: the
# sourcing script sets `set -euo pipefail` and these globals first.
#   DEFAULT_BRANCH       the branch alpha/beta (and a pre-branch rc) come from
#   LINE_BRANCH_FORMAT   printf format over (major, minor) for a line branch
#   LINE_BRANCH_PATTERN  regex that matches a line branch name
#
# The version grammar matches loft-sh/semstat's `validate` and `type` on purpose,
# with one deliberate difference: build metadata is refused here, since nothing
# in the release pipeline handles it in a tag. It stays in bash so a release cut
# does not depend on downloading semstat.
#
# Nothing here mutates GitHub, so every function is safe to call in dry-run.
# The probes fail closed: a transient API error exits rather than reading as
# "absent".

# trim <string> -> the string without leading/trailing whitespace.
# Every operator-supplied input goes through this: the same paste that drops a
# space next to a version drops one next to a branch name, and an untrimmed
# branch fails the routing matrix with a message that quotes back a value
# looking identical to the expected one.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# flatten <string> -> the string on one line.
# Applied to operator input where it is READ, not where it is printed: a newline
# in a version or a branch name is never legitimate, and every error
# path downstream quotes the value back into a ::error:: annotation, where a
# second line would be parsed by GitHub as its own workflow command. Doing it at
# the single read point is what keeps that guarantee from depending on each
# message remembering to flatten.
flatten() {
  printf '%s' "$1" | LC_ALL=C tr '\n\r\t' '   '
}

# normalize_version <raw> -> canonical vX.Y.Z[-suffix]
# Operators paste versions from Linear, Slack and release notes, where the
# leading v is inconsistent and a stray space survives a copy. The routing
# helpers below already tolerate both spellings (parse_major_minor strips an
# optional v), but the raw string is used VERBATIM as the tag name and as the
# double-cut probe key - so an un-normalized "4.11.2" would create a v-less tag
# AND sail past the double-cut guard, which probes for "v4.11.2" and gets a 404.
# That silently re-releases an already-shipped version, and the resulting tag
# can never be resolved by the Go module proxy, which requires the v.
normalize_version() {
  local v
  v="$(trim "$1")"
  [[ "$v" == V* ]] && v="v${v#V}"   # accept a capitalized V
  [[ "$v" == v* ]] || v="v${v}"     # supply the leading v when missing
  printf '%s\n' "$v"
}

# validate_version <version> - hard-fail anything that is not our tag shape.
# Runs AFTER normalize_version, so a recoverable paste (missing v, capitalized
# V, stray whitespace) has already been repaired and only genuinely malformed
# input reaches here. Deliberately STRICTER than semver, because the value is
# used verbatim as a git tag and every downstream consumer assumes
# vMAJOR.MINOR.PATCH:
#   vX.Y     is not a release version; hack/version treats a bare major.minor as
#            a line, so tagging one produces a version nothing downstream can
#            resolve.
#   vX.Y.Z.N is not semver at all.
#   4.11.2   bare semver cannot be resolved by the Go module proxy;
#            normalize_version has already fixed it by here.
#   v4.11.02 a leading zero is not semver either, and it is the typo shape
#            nothing downstream catches: it normalizes unchanged, derives the
#            line release-4.11 (which exists), and probes clean against the
#            double-cut guard because the shipped tag is v4.11.2. Every numeric
#            component is therefore `0|[1-9][0-9]*`, in the prerelease too.
# Build metadata (+meta) is rejected too: no consumer in the pipeline handles it.
# The prerelease body is shape-checked to semver's own identifier grammar here -
# which also rejects an empty identifier (`-rc.`, `-rc..1`) - and classify_suffix
# decides which of the well-formed suffixes are actually routable.
validate_version() {
  local v="$1"
  local num='(0|[1-9][0-9]*)'
  local ident='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
  if [[ ! "$v" =~ ^v$num\.$num\.$num(-$ident(\.$ident)*)?$ ]]; then
    echo "::error::version '${v}' is not a valid release version. Expected vMAJOR.MINOR.PATCH with an optional prerelease suffix, e.g. v4.11.2, v4.12.0-rc.1, v4.13.0-next.internal.3." >&2
    return 1
  fi
}

# parse_major_minor <version> -> "MAJOR MINOR"
# Accepts v-prefixed or bare, with or without patch/prerelease:
#   v4.11.2-rc.1 -> "4 11", v5.0 -> "5 0". Fails loudly on garbage.
parse_major_minor() {
  local v="${1#v}" major minor rest
  major="${v%%.*}"
  rest="${v#*.}"
  minor="${rest%%.*}"
  # Trim any non-numeric suffix on the minor (e.g. "11-rc.1" -> "11").
  minor="${minor%%[!0-9]*}"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]]; then
    echo "::error::cannot parse major.minor from version '$1'" >&2
    return 1
  fi
  printf '%s %s\n' "$major" "$minor"
}

# derive_line <version> -> the release-line branch name (release-X.Y)
derive_line() {
  local mm major minor
  mm="$(parse_major_minor "$1")" || return 1
  read -r major minor <<<"$mm"
  # shellcheck disable=SC2059 # LINE_BRANCH_FORMAT is the format string by design
  printf "${LINE_BRANCH_FORMAT}\n" "$major" "$minor"
}

# classify_suffix <version> -> alpha | beta | rc | next | next-internal | stable
# Fail-closed: only the prerelease suffixes the dispatcher knows how to route
# are accepted. Anything else - including a legal-but-unrouted tag such as
# -devpod.alpha, of which loft-enterprise has historical examples - is rejected so an
# unhandled release type can never be silently misrouted onto the wrong branch.
# Matching is anchored at the start of the prerelease body rather than anywhere
# in the string: an unanchored glob classifies -devpod-alpha.1 as a plain alpha
# and cuts it from main, so the fail-closed guarantee would hold for the dotted
# spelling of an unrouted flavor and quietly leak on the dashed one.
# validate_version runs first, so the first '-' is always the prerelease
# delimiter.
# Order matters: next.internal is a sub-flavor of next and must match first.
classify_suffix() {
  local v="$1" body
  [[ "$v" == *-* ]] || { printf 'stable\n'; return 0; }
  body="${v#*-}"
  # Anchored regexes, not globs: a `rc.*` glob also matches an empty tail, and
  # `v4.12.0-rc.` would be a tag the Go module proxy cannot resolve. next.internal
  # is tested before next so `next.internal.3` is not claimed by the looser arm.
  if   [[ "$body" =~ ^next\.internal\.[0-9]+$ ]]; then printf 'next-internal\n'
  elif [[ "$body" =~ ^next\.[0-9]+$ ]];           then printf 'next\n'
  elif [[ "$body" =~ ^alpha\.[0-9]+$ ]];          then printf 'alpha\n'
  elif [[ "$body" =~ ^beta\.[0-9]+$ ]];           then printf 'beta\n'
  elif [[ "$body" =~ ^rc\.[0-9]+$ ]];             then printf 'rc\n'
  else
    # Spelled with the numeric component the patterns require: a bare -rc is
    # rejected here too, and a message advertising "-rc" would send the
    # operator hunting for a bug in the classifier instead of fixing the tag.
    echo "::error::version '$v' has an unsupported prerelease suffix; the dispatcher cuts only -alpha.N/-beta.N/-rc.N/-next.N/-next.internal.N or a stable vX.Y.Z" >&2
    return 1
  fi
}

# is_feature_branch <branch> -> 0 for a short-lived feature branch, 1 otherwise.
# A feature branch is anything that is neither the default branch nor a
# release-X.Y line branch.
is_feature_branch() {
  local b="$1"
  [[ "$b" == "$DEFAULT_BRANCH" ]] && return 1
  [[ "$b" =~ $LINE_BRANCH_PATTERN ]] && return 1
  return 0
}

# validate_branch <branch> -> 0 when the value is a plausible git branch name.
#
# Every branch is interpolated straight into a `gh api` path, and gh reads `?`
# as the start of a query string. `main?` would pass is_feature_branch as "not
# main" and then resolve to main at every endpoint, putting a -next tag on the
# default branch. An allowlist, since only branch-shaped values should reach a URL.
# A path segment starting with `.` goes too: git refuses it in a ref name, and a
# `main/.` that some hop normalizes to `main` is the same bypass as `main?`.
validate_branch() {
  local b="$1"
  if [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] &&
     [[ "$b" != -* && "$b" != .* && "$b" != /* && "$b" != */ && "$b" != *".."* && "$b" != *"/."* ]]; then
    return 0
  fi
  # Already flattened where it was read, so it cannot forge a second command.
  echo "::error::source-branch '${b}' is not a valid branch name. Expected letters, digits and '.', '_', '-', '/' only, with no leading '-' or '.', no leading or trailing '/', no path segment starting with '.', and no '..'." >&2
  return 1
}

# resolve_target <suffix> <source-branch> <line> -> the branch to tag, or a hard
# error if <source-branch> violates the matrix. Handles the non-feature suffixes
# only (alpha/beta/rc/stable); next/next.internal are routed by the caller.
#   alpha|beta -> main only
#   rc         -> main or the line branch release-X.Y (the caller has already
#                 narrowed this through resolve_rc_source, which refuses main
#                 once release-X.Y exists)
#   stable     -> the line branch release-X.Y only
# Pure and network-free: every fact it needs is an argument. The branch-state
# probe lives in resolve_rc_source so its transient-failure abort fires in the caller
# rather than inside the command substitution that calls this - where it would
# kill only the subshell and be misread as a routing rejection.
resolve_target() {
  local suffix="$1" src="$2" line="$3"
  case "$suffix" in
    alpha|beta)
      if [[ -n "$src" && "$src" != "$DEFAULT_BRANCH" ]]; then
        echo "::error::${suffix} releases are cut from ${DEFAULT_BRANCH} only, not '${src}'" >&2
        return 1
      fi
      printf '%s\n' "$DEFAULT_BRANCH" ;;
    rc)
      # Which of the two branches is legal depends on whether the line has
      # branched, which only resolve_rc_source knows. An empty src means that
      # probe was skipped, and defaulting to main here would bypass its refusal.
      if [[ -z "$src" ]]; then
        echo "::error::resolve_target: an rc needs its source branch resolved by resolve_rc_source first" >&2
        return 1
      fi
      if [[ "$src" == "$DEFAULT_BRANCH" ]]; then
        printf '%s\n' "$DEFAULT_BRANCH"
      elif [[ "$src" == "$line" ]]; then
        printf '%s\n' "$line"
      else
        echo "::error::rc releases are cut from ${DEFAULT_BRANCH} or the ${line} release branch, not '${src}'" >&2
        return 1
      fi ;;
    stable)
      if [[ -n "$src" && "$src" != "$line" ]]; then
        echo "::error::stable releases are cut from the ${line} release branch only, not '${src}'" >&2
        return 1
      fi
      printf '%s\n' "$line" ;;
    *)
      echo "::error::resolve_target: unexpected suffix '${suffix}'" >&2
      return 1 ;;
  esac
}

# gh_reason <raw> - gh's own words from a `--silent -i` capture, on one line.
#
# The capture is a response-header block with gh's error appended, so
# interpolating it whole pushes the sentence that says WHY past the point where
# GitHub truncates an annotation. The status line and `Name: value` headers carry
# nothing the message does not already state, so they go. Flattening \n\r\t keeps
# a multi-line body from breaking the annotation or forging a second workflow
# command.
gh_reason() {
  local raw="$1" reason
  [[ -n "$raw" ]] || { printf '<no output>'; return 0; }
  # `gh: ...` is kept explicitly, because it matches the `Name: value` shape a
  # response header has and a bare header filter eats the one line worth
  # printing.
  reason="$(printf '%s\n' "$raw" | awk '
      /^gh:/ { print; next }
      /^HTTP\// { next }
      /^[A-Za-z][A-Za-z0-9-]*: / { next }
      { print }
    ' | LC_ALL=C tr '\n\r\t' '   ' | tr -s ' ' | sed 's/^ *//; s/ *$//' || true)"
  # Headers but no reason is itself worth saying: it means gh returned a status
  # and died without explaining, which reads very differently from no output.
  printf '%s' "${reason:-<no reason in gh output>}"
}

# run_captured <out-var> <err-var> <command...> - run a command with its stdout
# and stderr captured into separate variables, and return its exit status.
#
# Kept apart because stdout is often parsed (a workflow file, a listing) and a
# stray notice on stderr would corrupt it, while stderr is what the failure
# message quotes. Assigned with printf -v, so both come back with their trailing
# newlines stripped, as a command substitution would. Stdin passes through.
run_captured() {
  local __rc_out_var="$1" __rc_err_var="$2" __rc_errfile __rc_out __rc_status=0
  shift 2
  __rc_errfile="$(mktemp)"
  __rc_out="$("$@" 2>"$__rc_errfile")" || __rc_status=$?
  printf -v "$__rc_err_var" '%s' "$(cat "$__rc_errfile")"
  rm -f "$__rc_errfile"
  printf -v "$__rc_out_var" '%s' "$__rc_out"
  return "$__rc_status"
}

# api_exists <path> <what> -> 0 if 200, 1 if 404, exits 1 on transient/unexpected.
# Shared read-only existence probe. Read only the HTTP status line. On a 404 `gh`
# exits non-zero, so we must capture its output with `|| true` BEFORE parsing -
# piping gh directly into the status-substitution would let pipefail propagate the
# non-zero exit and clobber the code to empty, misreading a real 404 as a transient
# failure. gh writes the "HTTP/2.0 404" status line to stdout even with --silent
# (only the body is suppressed); a genuine transient error (DNS/auth/rate-limit)
# yields no status line, so an empty code correctly means "could not reach the API".
# Distinguishing the two matters to every caller: an unreachable API must never be
# silently read as "absent" (a missed double-cut guard) or "missing" (a wrong branch).
api_exists() {
  local path="$1" what="$2" out http_code
  # stderr is merged, not discarded. On the no-status path gh's own message is
  # the only evidence of what went wrong, and dropping it leaves the operator
  # with a diagnosis ("DNS, rate-limit, or auth") that names three causes and
  # distinguishes none of them. Merging is safe because the status line is
  # matched by prefix rather than by position.
  out="$(gh api "$path" --silent -i 2>&1 || true)"
  # `|| true` is load-bearing under `set -o pipefail`: on the no-status path grep
  # matches nothing and exits 1, which would abort the script here and skip the
  # very diagnostic this function exists to print.
  http_code="$(printf '%s\n' "$out" | grep -m1 '^HTTP/' | awk '{print $2}' || true)"
  case "$http_code" in
    200) return 0 ;;
    404) return 1 ;;
    "")
      echo "::error::failed to reach GitHub API for ${what} (no HTTP status - DNS, rate-limit, or auth). Not treating as absent. gh said: $(gh_reason "$out")" >&2
      exit 1
      ;;
    *)
      # gh's own words, not just the code: a 403 is where secondary rate limits
      # and SSO/scope rejections land, and the status alone distinguishes none of
      # them.
      echo "::error::unexpected status ${http_code} from GitHub API for ${what}. gh said: $(gh_reason "$out")" >&2
      exit 1
      ;;
  esac
}

# api_get <out-var> <path> <what> <jq> -> 0 with the jq-filtered body in <out-var>
# on a 200, 1 on a 404, exits 1 on anything else. api_exists for a caller that
# also needs the body, so one request answers both questions.
#
# stderr is kept apart from the body, which gets parsed, and quoted only when
# something fails. On a 200 gh prints the response headers, a blank line, then
# the filtered body; on a 404 it prints the headers and exits non-zero, so the
# exit status is ignored and the status line decides. Exits rather than returns
# on a failure, so call it directly, not inside a command substitution, when
# that exit has to end the script.
api_get() {
  local __ag_var="$1" __ag_path="$2" __ag_what="$3" __ag_filter="$4" __ag_out __ag_err __ag_code
  run_captured __ag_out __ag_err gh api -i "$__ag_path" --jq "$__ag_filter" || true
  __ag_code="$(printf '%s\n' "$__ag_out" | grep -m1 '^HTTP/' | awk '{print $2}' || true)"
  case "$__ag_code" in
    200)
      printf -v "$__ag_var" '%s' "$(printf '%s\n' "$__ag_out" | awk 'body { print } /^\r?$/ { body = 1 }')"
      return 0 ;;
    404) return 1 ;;
    "")
      echo "::error::failed to reach GitHub API for ${__ag_what} (no HTTP status - DNS, rate-limit, or auth). Not treating as absent. gh said: $(gh_reason "$__ag_err")" >&2
      exit 1 ;;
    *)
      echo "::error::unexpected status ${__ag_code} from GitHub API for ${__ag_what}. gh said: $(gh_reason "$__ag_err")" >&2
      exit 1 ;;
  esac
}

# branch_exists <repo> <branch> -> 0 if 200, 1 if 404, exits 1 on transient error.
branch_exists() {
  local repo="$1" branch="$2"
  api_exists "repos/${repo}/branches/${branch}" "branch '${branch}' in ${repo}"
}

# require_branch <repo> <branch> - hard error if the branch is absent.
require_branch() {
  local repo="$1" branch="$2"
  if ! branch_exists "$repo" "$branch"; then
    echo "::error::branch '${branch}' not found in ${repo}. Create it (and its workflow_dispatch-enabled release.yaml) before cutting this line - refusing to guess." >&2
    exit 1
  fi
}

# resolve_rc_source <repo> <line> <src> -> the branch an rc is cut from, or a
# hard error when <src> contradicts the line's actual state.
#
# rc is the one suffix legal from either branch, and which of the two is right is
# not a preference - it is decided by whether the line has branched yet:
#
#   release-X.Y exists   the rc MUST come from release-X.Y. main now carries the
#                        NEXT line's development and is missing the backports
#                        that only land on release-X.Y, so an rc cut from it
#                        validates the wrong code. An empty source-branch takes
#                        release-X.Y; an explicit main is refused rather than
#                        honoured, because at this point it is a mistake and
#                        nothing downstream would catch it.
#   release-X.Y absent   the rc IS main; that is where the line lives until it
#                        branches.
#
# So the probe is not just a default-filler: it runs on every rc, including one
# that named a source branch, because the refusal above depends on it.
# branch_exists is fail-closed (a transient API error aborts rather than reading
# as absent), so an unreachable API can neither silently pick main nor silently
# skip the refusal.
#
# A source branch that is neither main nor release-X.Y is passed through
# untouched for resolve_target to reject, keeping that error in one place.
resolve_rc_source() {
  local repo="$1" line="$2" src="$3"
  if branch_exists "$repo" "$line"; then
    if [[ -z "$src" ]]; then
      echo "::notice::no source-branch given for an rc and ${line} exists in ${repo}; cutting from ${line}." >&2
      printf '%s\n' "$line"
      return 0
    fi
    if [[ "$src" == "$DEFAULT_BRANCH" ]]; then
      echo "::error::${line} exists in ${repo}, so an rc on this line is cut from ${line}, not from ${DEFAULT_BRANCH}. ${DEFAULT_BRANCH} carries the next line's development and lacks the fixes backported to ${line}, so this rc would validate the wrong code. Pass source-branch: ${line}, or leave source-branch empty to take it automatically." >&2
      return 1
    fi
    printf '%s\n' "$src"
    return 0
  fi
  if [[ -z "$src" ]]; then
    echo "::notice::no source-branch given for an rc and ${line} does not exist yet in ${repo}; cutting from ${DEFAULT_BRANCH}." >&2
    printf '%s\n' "$DEFAULT_BRANCH"
    return 0
  fi
  printf '%s\n' "$src"
}

# require_unbranched <repo> <line> <suffix> - alpha/beta come from main only, and
# once release-X.Y exists main carries the next line, so an alpha or beta of this
# line would tag code the line will never ship. Refused rather than rerouted: the
# line branch is where rcs come from, not prereleases of an earlier stage.
require_unbranched() {
  local repo="$1" line="$2" suffix="$3"
  if branch_exists "$repo" "$line"; then
    echo "::error::${line} exists in ${repo}, so ${DEFAULT_BRANCH} now carries the next line and a ${suffix} of this line would tag the wrong code. Cut an rc from ${line} instead. Nothing was tagged." >&2
    exit 1
  fi
}

#!/usr/bin/env bash
# Promote a just-published stable release: retag docker moving tags onto the
# version's already-published, already-signed manifest (a digest-preserving
# copy via `docker buildx imagetools create`, never a rebuild -- cosign
# signatures are digest-scoped OCI referrers, so the copy stays verifiable
# with no re-signing), and optionally flip a paired public release off
# pre-release + onto latest.
#
# Only acts on a stable vX.Y.Z version; any other shape (has a "-" suffix) is
# a no-op, since moving tags and "latest" promotion aren't meaningful for
# -rc/-alpha/-next cuts.
#
# Required env:
#   GH_TOKEN        Token with GHCR write:packages, and contents:write on
#                    INPUT_OSS_REPO and INPUT_HOMEBREW_TAP_REPO if set. Docker
#                    login happens in the calling action.yml step, before this
#                    script runs.
#   INPUT_VERSION    The promoted release tag, e.g. v0.37.1.
#   INPUT_IMAGES     JSON array of image entries to retag, each
#                    {"image": "ghcr.io/loft-sh/x", "suffix": ""} (suffix
#                    optional, default ""). For each entry, copies
#                    <image>:<version><suffix> to <image>:latest<suffix>,
#                    <image>:<major><suffix>, and <image>:<major>.<minor><suffix>.
#
# Optional env:
#   INPUT_OSS_REPO   owner/repo whose matching <version> release should also
#                     be promoted. Empty (default) skips this step. Required
#                     if INPUT_HOMEBREW_TAP_REPO is set (checksums for the
#                     tap come from this repo's <version> release).
#   INPUT_HOMEBREW_TAP_REPO
#                    owner/repo of a Homebrew tap to promote (e.g.
#                     loft-sh/homebrew-tap). Empty (default) skips this step.
#   INPUT_HOMEBREW_FORMULA_PATHS
#                    JSON array of formula file paths within
#                     INPUT_HOMEBREW_TAP_REPO to update, e.g.
#                     ["Formula/vcluster.rb"]. Required if
#                     INPUT_HOMEBREW_TAP_REPO is set.
#   INPUT_DRY_RUN    Fail-closed: a real promotion runs only on an exact
#                     (case-insensitive) "false" - which is the default, so the
#                     release:released trigger still promotes for real. ANY
#                     other value ("true", "yes", "1", a typo, wrong case,
#                     stray whitespace) is a dry-run that only prints the
#                     planned retags/promotion, so a caller who meant to
#                     preview can't accidentally fire a real retag/release flip.
#
# GITHUB_REPOSITORY (owner/repo of the caller, set automatically by Actions)
# is used to detect a backport/patch promotion: if VERSION isn't the newest
# stable release on that repo, :latest/:{major} are left alone so promoting an
# older line's patch can never move :latest backwards. :{major}.{minor} is
# scoped to VERSION's own line, so it advances on its own gate: only when
# VERSION is the newest stable *within its own {major}.{minor} line*. That
# keeps a same-line out-of-order promotion (e.g. un-checking pre-release on
# v9.9.5 after v9.9.6 already moved :9.9) from regressing the line tag too.
#
# Homebrew promotion is a metadata patch, not a rebuild: a formula's per-
# platform sha256 values are exactly what's already in oss-repo's <version>
# release checksums.txt (already published, already cosign-signed), so
# there's nothing to re-hash. Only the version line and each url/sha256
# pair are rewritten in place - everything else in the formula (deps,
# install blocks, test block) is preserved byte-for-byte, so the patch can't
# drift from whatever template shape generated the file.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${INPUT_VERSION:?version required}"
: "${INPUT_IMAGES:?images required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required (set automatically by GitHub Actions)}"

VERSION="${INPUT_VERSION}"
OSS_REPO="${INPUT_OSS_REPO-}"
HOMEBREW_TAP_REPO="${INPUT_HOMEBREW_TAP_REPO-}"
HOMEBREW_FORMULA_PATHS="${INPUT_HOMEBREW_FORMULA_PATHS:-[]}"
# Fail closed: real mutations run only on an explicit, unambiguous "false"
# (the input default, so the auto-promotion trigger still fires for real). Any
# other value - "true", "yes", "1", a typo, wrong case, stray whitespace -
# stays in dry-run, so a caller who meant to preview can never accidentally
# fire a real GHCR retag or release flip. Mirrors the sibling vcluster-release
# action's dry-run contract.
raw_dry_run="${INPUT_DRY_RUN:-false}"
case "${raw_dry_run,,}" in
  false) DRY_RUN="false" ;;
  true)  DRY_RUN="true" ;;
  *)
    echo "::warning::unrecognized dry-run value '${raw_dry_run}'; defaulting to dry-run (no mutations). Pass exactly 'false' to promote for real." >&2
    DRY_RUN="true"
    ;;
esac

if [[ -n "${HOMEBREW_TAP_REPO}" ]]; then
  if [[ -z "${OSS_REPO}" ]]; then
    echo "::error::homebrew-tap-repo requires oss-repo to be set (checksums come from oss-repo's release)" >&2
    exit 1
  fi
  if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"${HOMEBREW_FORMULA_PATHS}"; then
    echo "::error::homebrew-formula-paths must be a non-empty JSON array when homebrew-tap-repo is set, got: ${HOMEBREW_FORMULA_PATHS}" >&2
    exit 1
  fi
fi

if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"${INPUT_IMAGES}"; then
  echo "::error::images must be a non-empty JSON array, got: ${INPUT_IMAGES}" >&2
  exit 1
fi

if [[ ! "${VERSION}" =~ ^v([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
  echo "::notice::${VERSION} is not a stable vX.Y.Z release; moving tags and latest promotion only apply to stable cuts. Nothing to do."
  exit 0
fi
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# True if VERSION is the newest stable (non-prerelease) release known on
# $1 - i.e. safe to move that repo's :latest/--latest pointer to VERSION.
# With $2 set to a "{major}.{minor}" line (e.g. "9.9"), the comparison is
# restricted to stable releases in that line only, answering "newest within
# its own minor line?" - which is what gates the line-scoped :{major}.{minor}
# tag, independently of "newest overall".
# No prior stable releases (in scope) at all is treated as "yes" (first-ever
# promotion).
#
# Return codes: 0 = newest (advance), 1 = not newest (don't advance).
# A failure to even LIST releases is NOT treated as "no prior releases" - that
# would fail open on exactly the downgrade this check exists to prevent. How a
# list failure is handled depends on $3:
#   "exit" (default): hard-exit non-zero. Correct for the pre-retag caller-repo
#     gates - if we can't determine ordering, do nothing loudly (matches the
#     Homebrew-tap downgrade guard's fail-closed precedent, release.yaml
#     check_latest_stable). A green no-op would silently hide a failed promotion.
#   "soft": warn and return 2. For the post-retag oss-repo gate, where the
#     irreversible docker retags are already done and this only decides the
#     advisory --latest flag; hard-exiting there would fail the run after the
#     main work succeeded without preventing any downgrade (we just skip
#     --latest, which never moves it backward).
is_latest_stable() {
  local repo="$1" line="${2-}" on_fail="${3:-exit}" raw max filter='^v[0-9]+\.[0-9]+\.[0-9]+$'
  # --limit must comfortably exceed the repo's lifetime release count: the
  # "empty result => advance" short-circuit below reads an empty list as "no
  # prior release (in scope) ever". For the line-scoped check that's the fail-
  # open edge - if a {major}.{minor} line's stable siblings all scrolled past a
  # too-small window, the filter finds none, ADVANCE_MINOR flips true, and the
  # line tag gets retagged backward. 1000 is ~a decade of headroom at current
  # cadence; gh paginates up to it in one call.
  if ! raw=$(gh release list --repo "${repo}" --json tagName,isPrerelease --limit 1000 2>&1); then
    if [[ "${on_fail}" == "soft" ]]; then
      echo "::warning::failed to list releases on ${repo} to confirm ${VERSION} is newest (${raw}); skipping the advisory --latest promotion. Docker retags already completed; set latest manually if appropriate." >&2
      return 2
    fi
    echo "::error::failed to list releases on ${repo} to check backport/patch ordering: ${raw}" >&2
    exit 1
  fi
  # Anchor the line filter on the literal, dot-escaped {major}.{minor} so a
  # "9.9" line never also matches "9x9" or a "99" prefix.
  [[ -n "${line}" ]] && filter="^v${line//./\\.}\.[0-9]+$"
  max=$(jq -r '[.[] | select(.isPrerelease == false) | .tagName][]' <<<"${raw}" \
    | grep -E "${filter}" \
    | sort -V | tail -1)
  [ -z "${max}" ] && return 0
  [ "$(printf '%s\n%s\n' "${VERSION}" "${max}" | sort -V | tail -1)" = "${VERSION}" ]
}

ADVANCE_LATEST_MAJOR=true
if ! is_latest_stable "${GITHUB_REPOSITORY}"; then
  ADVANCE_LATEST_MAJOR=false
  echo "::notice::${VERSION} is not the newest stable release on ${GITHUB_REPOSITORY} (backport/patch promotion); skipping :latest/:${MAJOR} so they aren't moved backwards."
fi

# :{major}.{minor} gets its own, line-scoped gate. When VERSION is newest
# overall this is necessarily also true, so the happy path is unchanged; the
# case it guards is a same-line out-of-order promotion where VERSION is NOT
# the newest patch in its own {major}.{minor} line - advancing :{major}.{minor}
# there would silently regress it to an older patch.
ADVANCE_MINOR=true
if ! is_latest_stable "${GITHUB_REPOSITORY}" "${MAJOR}.${MINOR}"; then
  ADVANCE_MINOR=false
  echo "::notice::${VERSION} is not the newest stable release in the ${MAJOR}.${MINOR} line on ${GITHUB_REPOSITORY}; skipping :${MAJOR}.${MINOR} so it isn't moved backwards within its own line."
fi

# Validate every entry - and that its source manifest actually exists at
# VERSION - before making any changes, so a config typo or a suffix variant
# (e.g. -fips) that wasn't built for this version can't leave earlier
# entries retagged while a later one fails. Skipped under dry-run, since
# nothing has been pushed to inspect yet in a rehearsal.
IMAGE_COUNT=$(jq -r 'length' <<<"${INPUT_IMAGES}")
for ((i = 0; i < IMAGE_COUNT; i++)); do
  entry=$(jq -c ".[$i]" <<<"${INPUT_IMAGES}")
  image=$(jq -r '.image // empty' <<<"${entry}")
  suffix=$(jq -r '.suffix // ""' <<<"${entry}")
  if [[ -z "${image}" ]]; then
    echo "::error::images[$i] is missing required \"image\" field: ${entry}" >&2
    exit 1
  fi
  if [[ "${DRY_RUN}" != "true" ]] && ! docker buildx imagetools inspect "${image}:${VERSION}${suffix}" >/dev/null 2>&1; then
    echo "::error::source manifest ${image}:${VERSION}${suffix} does not exist; refusing to start retagging" >&2
    exit 1
  fi
done

# --- Docker moving tags ------------------------------------------------

for ((i = 0; i < IMAGE_COUNT; i++)); do
  entry=$(jq -c ".[$i]" <<<"${INPUT_IMAGES}")
  image=$(jq -r '.image' <<<"${entry}")
  suffix=$(jq -r '.suffix // ""' <<<"${entry}")

  src="${image}:${VERSION}${suffix}"
  moving_tags=()
  [[ "${ADVANCE_LATEST_MAJOR}" == "true" ]] && moving_tags+=(latest "${MAJOR}")
  [[ "${ADVANCE_MINOR}" == "true" ]] && moving_tags+=("${MAJOR}.${MINOR}")
  if [[ "${#moving_tags[@]}" -eq 0 ]]; then
    echo "::notice::${src}: no moving tags to advance (VERSION is superseded both overall and within its own line); nothing to retag."
    continue
  fi
  for moving in "${moving_tags[@]}"; do
    dest="${image}:${moving}${suffix}"
    echo "Retagging ${dest} -> ${src}"
    run docker buildx imagetools create --tag "${dest}" "${src}"
  done
done

# --- Paired public release ----------------------------------------------

# Whether VERSION is the newest stable on OSS_REPO. Computed once, in the
# block below, and reused by the Homebrew section - so the advisory Homebrew
# step doesn't fire a second `gh release list` (that duplicated the work and,
# via is_latest_stable's fail-closed exit, could hard-fail the whole run for a
# transient list blip after everything else already succeeded). Four states:
#   "true"    - VERSION is newest; promote --latest and the Homebrew tap.
#   "false"   - confirmed backport; skip --latest and skip Homebrew (a formula
#               has no line-scoped equivalent to :{major}.{minor}).
#   "unknown" - list failed, couldn't confirm; skip --latest and Homebrew but
#               warn it's retryable, NOT a backport.
#   ""        - never computed (no matching oss-repo release, or no oss-repo).
OSS_IS_LATEST=""
if [[ -n "${OSS_REPO}" ]]; then
  if gh release view "${VERSION}" --repo "${OSS_REPO}" >/dev/null 2>&1; then
    edit_args=(--prerelease=false)
    latest_note=""
    # "soft": a list failure here must not hard-fail the run (docker retags are
    # already done and this only gates the advisory --latest). Capture the code
    # via `|| oss_rc=$?` so `set -e` doesn't exit on the non-zero return.
    oss_rc=0
    is_latest_stable "${OSS_REPO}" "" "soft" || oss_rc=$?
    if [[ "${oss_rc}" -eq 0 ]]; then
      OSS_IS_LATEST=true
      edit_args+=(--latest)
      latest_note=", set latest"
    elif [[ "${oss_rc}" -eq 1 ]]; then
      OSS_IS_LATEST=false
      echo "::notice::${VERSION} is not the newest stable release on ${OSS_REPO} (backport/patch promotion); unsetting pre-release but not moving Latest."
    else
      # rc 2 = could not confirm (list failure; is_latest_stable already warned
      # about the --latest skip). Kept DISTINCT from a confirmed backport
      # (false) so the downstream Homebrew gate warns accurately instead of
      # mislabeling a transient blip as a backport and silently leaving the
      # formula stale. Prerelease is still unset; only --latest is withheld.
      OSS_IS_LATEST=unknown
    fi
    echo "Promoting ${OSS_REPO}@${VERSION}: unset prerelease${latest_note}"
    if ! run gh release edit "${VERSION}" --repo "${OSS_REPO}" "${edit_args[@]}"; then
      echo "::warning::gh release edit failed for ${OSS_REPO}@${VERSION}; docker retags are already complete. Promote manually: gh release edit ${VERSION} --repo ${OSS_REPO} ${edit_args[*]}"
    fi
  else
    echo "::warning::no ${VERSION} release found on ${OSS_REPO}; skipping its promotion"
  fi
else
  echo "No oss-repo configured; skipping paired release promotion"
fi

# --- Homebrew tap --------------------------------------------------------
#
# Patches an existing formula file in place rather than re-templating it:
# swap every url's tag segment (every platform in a formula shares the same
# tag), rewrite the sha256 on the line immediately following each url - the
# value comes straight from oss-repo's already-published, already-signed
# checksums.txt, never re-hashed - and rewrite the single top-level version
# line. Everything else in the file (deps, install blocks, test block) is
# untouched byte-for-byte.
#
# All matching/rewriting of interpolated values (the tag, the artifact names)
# is done with awk literal string ops (index/substr), never by splicing those
# values into a regex. A tag like v0.37.1 or an artifact name containing a "."
# or "+" would, as a regex, match any character and could rewrite the wrong
# line; as a literal it matches only itself. The version rewrite is likewise
# anchored to the first top-level (2-space-indent) `version "..."` so a nested
# `resource "..." do ... version "..." ... end` pin is left alone.

# Rewrites $2 (a local copy of the formula) to point at $1 (the promoted
# version), using checksums from $3 (a local copy of oss-repo's
# checksums.txt). Skips (warns, returns 0) rather than fails on any error,
# since Homebrew promotion is advisory - the docker retags (and oss-repo
# promotion, if configured) already succeeded by the time this runs.
patch_homebrew_formula() {
  local new_tag="$1" content_file="$2" checksums_file="$3" tap_repo="$4" formula_path="$5"
  local old_tag

  # `|| true`: under `set -euo pipefail` a no-match `grep` (exit 1) would
  # propagate through the pipe and kill the run before the warn-and-skip
  # guard below can handle it - the opposite of this advisory step's contract.
  old_tag=$(grep -oP 'download/\K[^/]+' "${content_file}" | head -1 || true)
  if [[ -z "${old_tag}" ]]; then
    echo "::warning::no download URL found in ${tap_repo}/${formula_path}; skipping"
    return 0
  fi
  # old_tag is read from the fetched formula, so a tap-repo committer controls
  # it. It's only ever used below as literal data (awk index/substr, never a
  # shell/sed/regex program), but validate it to a release-tag shape anyway as
  # defense-in-depth: bounding it to [v0-9.-] means it can't carry awk -v
  # ANSI-C escape sequences, and a formula not pinned to a recognizable release
  # tag is a shape this promoter doesn't understand - warn-skip over mangle.
  if [[ ! "${old_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]]; then
    echo "::warning::unrecognized version tag '${old_tag}' in ${tap_repo}/${formula_path}; skipping"
    return 0
  fi

  # Single literal-string pass: for each url line, swap old_tag->new_tag,
  # capture the artifact (the url's trailing path segment), and rewrite the
  # sha256 on the very next line from checksums.txt; rewrite only the first
  # top-level `version "..."`. No interpolated value is ever used as a regex.
  awk -v old_tag="${old_tag}" -v new_tag="${new_tag}" -v new_ver="${new_tag#v}" \
      -v checksums="${checksums_file}" -v tap="${tap_repo}" \
      -v fp="${formula_path}" -v ossrepo="${OSS_REPO}" '
    BEGIN {
      # checksums.txt lines are "<sha>  <filename>"; default FS handles the
      # leading/trailing whitespace and the two-space separator.
      while ((getline line < checksums) > 0)
        if (split(line, f) >= 2) sha[f[2]] = f[1]
      old_url = "download/" old_tag "/"
      new_url = "download/" new_tag "/"
    }
    {
      pos = index($0, old_url)
      if (pos > 0) {
        $0 = substr($0, 1, pos - 1) new_url substr($0, pos + length(old_url))
        rest = substr($0, pos + length(new_url))
        q = index(rest, "\""); if (q > 0) rest = substr(rest, 1, q - 1)
        print
        if ((getline shaline) > 0) {
          if (rest in sha) {
            p = index(shaline, "sha256 \"")
            if (p > 0) {
              head = substr(shaline, 1, p - 1) "sha256 \""
              tail = substr(shaline, p + length("sha256 \""))
              qq = index(tail, "\"")
              if (qq > 0) shaline = head sha[rest] substr(tail, qq)
            }
          } else {
            print "::warning::" tap "/" fp ": no checksum for " rest " in " ossrepo "@" new_tag " checksums.txt; leaving its sha256 untouched" > "/dev/stderr"
          }
          print shaline
        }
        next
      }
      if (!ver_done && $0 ~ /^  version "[^"]*"/) {
        sub(/version "[^"]*"/, "version \"" new_ver "\"")
        ver_done = 1
      }
      print
    }
  ' "${content_file}" > "${content_file}.next"
  mv "${content_file}.next" "${content_file}"
}

promote_homebrew_formula() {
  local tap_repo="$1" formula_path="$2" checksums_file="$3"
  local get_raw current_sha content_file new_content_b64

  if ! get_raw=$(gh api "repos/${tap_repo}/contents/${formula_path}" 2>&1); then
    echo "::warning::failed to fetch ${tap_repo}/${formula_path}; skipping: ${get_raw}"
    return 0
  fi
  # `// empty` (not a bare `.sha`): jq renders a missing/null field as the
  # literal string "null", which is non-empty and would sail into `-f sha=`
  # on the PUT below and 422. Guard it here so an unexpected response
  # warn-skips instead of silently leaving the formula unpatched.
  current_sha=$(jq -r '.sha // empty' <<<"${get_raw}")
  if [[ -z "${current_sha}" ]]; then
    echo "::warning::unexpected API response for ${tap_repo}/${formula_path} (missing sha field); skipping"
    return 0
  fi
  content_file=$(mktemp)
  # Guard the decode: it's the one step in this advisory block that could
  # otherwise hard-fail the run post-retag (jq/base64 failure would propagate
  # under `set -euo pipefail`). Warn-skip instead, like every other step here.
  if ! jq -r '.content' <<<"${get_raw}" | base64 -d > "${content_file}" 2>/dev/null; then
    echo "::warning::failed to decode ${tap_repo}/${formula_path} contents (unexpected API response); skipping"
    return 0
  fi

  patch_homebrew_formula "${VERSION}" "${content_file}" "${checksums_file}" "${tap_repo}" "${formula_path}"

  echo "Updating ${tap_repo}/${formula_path} -> ${VERSION}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] gh api -X PUT repos/${tap_repo}/contents/${formula_path} (sha=${current_sha})"
    return 0
  fi
  new_content_b64=$(base64 -w0 "${content_file}")
  if ! gh api -X PUT "repos/${tap_repo}/contents/${formula_path}" \
      -f message="chore: bump ${formula_path} to ${VERSION}" \
      -f content="${new_content_b64}" \
      -f sha="${current_sha}" >/dev/null; then
    echo "::warning::failed to update ${tap_repo}/${formula_path} to ${VERSION}; docker retags (and oss-repo promotion, if configured) already succeeded. Re-run this action to retry the tap update - it is idempotent (imagetools create and the formula patch both re-apply cleanly)."
  fi
}

if [[ -n "${HOMEBREW_TAP_REPO}" ]]; then
  case "${OSS_IS_LATEST}" in
    true)
      checksums_file=$(mktemp)
      if ! gh release download "${VERSION}" --repo "${OSS_REPO}" -p 'checksums.txt' -O "${checksums_file}" --clobber 2>&1; then
        echo "::warning::failed to download checksums.txt from ${OSS_REPO}@${VERSION}; skipping Homebrew tap promotion"
      else
        formula_count=$(jq -r 'length' <<<"${HOMEBREW_FORMULA_PATHS}")
        for ((i = 0; i < formula_count; i++)); do
          formula_path=$(jq -r ".[$i]" <<<"${HOMEBREW_FORMULA_PATHS}")
          promote_homebrew_formula "${HOMEBREW_TAP_REPO}" "${formula_path}" "${checksums_file}"
        done
      fi
      ;;
    false)
      echo "::notice::${VERSION} is not the newest stable release on ${OSS_REPO} (backport/patch promotion); skipping Homebrew tap promotion entirely - a formula has no line-scoped equivalent to :{major}.{minor}."
      ;;
    unknown)
      # Distinct from a backport: we couldn't confirm newest (the oss-repo list
      # failed earlier), so skip rather than risk patching the tap off a stale
      # ordering - but say so accurately and flag it as retryable, since a real
      # newest-release promotion may have just been skipped by a transient blip.
      echo "::warning::could not confirm ${VERSION} is the newest stable release on ${OSS_REPO} (its release list failed earlier); skipping Homebrew tap promotion. Re-run the action to update the tap once the API recovers."
      ;;
    *)
      # "" : the oss-repo release wasn't found above (already warned); without
      # it there are no published checksums to patch from.
      echo "::warning::no ${VERSION} release on ${OSS_REPO} to source checksums from; skipping Homebrew tap promotion"
      ;;
  esac
else
  echo "No homebrew-tap-repo configured; skipping Homebrew tap promotion"
fi

echo "Promotion of ${VERSION} complete."

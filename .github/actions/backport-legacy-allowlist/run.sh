#!/usr/bin/env bash
set -euo pipefail

# Gate backport-to-* labels to in-support pre-monorepo (<= v0.36) release lines.
#
# The monorepo era boundary is v0.37: lines >= v0.37 share the monorepo layout
# and are backported by the plain cherry-pick path, so they are dropped here.
# Lines <= v0.36 use the split/re-root flow (see backport-legacy-split), but only
# while they are still in support -- backporting a security fix onto an
# end-of-life line is wasted work and can mislead consumers into thinking a dead
# line is maintained.
#
# Support is read from the vCluster lifecycle doc so the gate self-prunes as
# lines reach EOL. Each requested line is checked against its OWN doc entry --
# not a min/max range -- so a non-contiguous lifecycle (e.g. an EOL line sitting
# between two supported ones) can't slip an EOL line through. A safety gate must
# fail closed in the direction it exists to block. Per requested 0.x minor:
#   - listed in the doc  -> allow iff status != "eol" AND eolDate is in the future
#   - not listed, above the highest listed 0.x minor (and <= MAX_MINOR)
#                        -> allow as a freshly cut line not yet in the doc (v0.36)
#   - otherwise          -> drop (EOL, or an unknown/gap line -> fail closed)
# On any fetch/parse failure we fall back to a contiguous [FALLBACK_MIN_MINOR,
# MAX_MINOR] window (the best we can do without the doc) so an outage never
# silently widens or empties the allow-list.
#
# Required environment variables:
#   LABELS              JSON array of PR label names, e.g. the output of
#                       toJSON(github.event.pull_request.labels.*.name). A
#                       blank value is treated as no labels.
#
# Optional environment variables:
#   LABEL_PREFIX        Backport label prefix (default backport-to-).
#   MAX_MINOR           Highest legacy 0.x minor (default 36).
#   LIFECYCLE_URL       Lifecycle JSON URL.
#   FALLBACK_MIN_MINOR  Lower-bound minor when the doc can't be read (default 31).
#   TODAY               Override "today" as YYYY-MM-DD (tests; default: UTC now).
#   GITHUB_OUTPUT       Actions output file; defaults to /dev/null off-CI.

# Provided (possibly empty) by the action's required `labels` input.
LABELS="${LABELS-}"
LABEL_PREFIX="${LABEL_PREFIX:-backport-to-}"
MAX_MINOR="${MAX_MINOR:-36}"
LIFECYCLE_URL="${LIFECYCLE_URL:-https://www.vcluster.com/docs/api/lifecycle/vcluster.json}"
FALLBACK_MIN_MINOR="${FALLBACK_MIN_MINOR:-31}"
TODAY="${TODAY:-$(date -u +%Y-%m-%d)}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

# --- lifecycle data --------------------------------------------------------
# have_doc=true when the doc parsed (so we can check each line's own eolDate).
# Only a FETCH/PARSE failure forces the contiguous fallback window -- a doc that
# parsed but lists no 0.x lines is NOT a failure: it means every legacy 0.x line
# is gone (vCluster fully on 1.x), so max_listed=-1 and nothing qualifies (fail
# closed). max_listed is the highest 0.x minor present; freshly cut lines are
# above it.
json=""
have_doc=false     # true once the doc is FETCHED; its content then governs
parsed=false       # true once jq extracted a valid max_listed from it
max_listed=-1
if json="$(curl -fsSL --max-time 20 "$LIFECYCLE_URL" 2>/dev/null)" && [ -n "$json" ]; then
  have_doc=true
  # Highest listed 0.x minor. Defensive at EVERY step so no doc shape can abort
  # the parse -- an abort would leave the fallback window in play and fail OPEN
  # (re-allow EOL lines), the trap the last three rounds kept hitting:
  #   (.versions?)[]?         tolerates a missing/non-array versions AND a
  #                           non-object top-level body (the `?` on the index too);
  #   select(type=="object")  drops scalar/array/bool rows before indexing .version;
  #   select(.version|type=="string")  drops rows with a missing/non-string version;
  #   tonumber?               drops a row whose minor isn't numeric ("0","0.x","0.36-rc").
  # On ANY valid JSON this yields a number or -1 and never errors; only a
  # genuinely non-JSON body makes jq fail.
  if ml="$(jq -r '
        [ (.versions?)[]?
          | select(type == "object")
          | select(.version | type == "string")
          | select((.version | split(".")[0]) == "0")
          | (.version | split(".")[1] | tonumber?)
        ] | max // -1
      ' <<<"$json" 2>/dev/null)" && [[ "$ml" =~ ^-?[0-9]+$ ]]; then
    parsed=true
    max_listed="$ml"
  fi
fi

# A FETCHED doc governs regardless of parseability: an unparseable body leaves
# max_listed=-1 and we FAIL CLOSED (allow nothing), never the widening fallback.
# The contiguous fallback is reserved for a genuine FETCH failure (curl/empty).
if $have_doc && [ "$max_listed" -ge 0 ]; then
  echo "lifecycle doc read; highest listed line v0.${max_listed} (today=${TODAY})"
elif $have_doc && $parsed; then
  echo "lifecycle doc read; no in-support 0.x lines listed -> all legacy lines treated as EOL (today=${TODAY})"
elif $have_doc; then
  echo "::warning::lifecycle doc from ${LIFECYCLE_URL} is not valid JSON; failing closed (treating all legacy lines as EOL)"
else
  echo "::warning::could not fetch lifecycle doc from ${LIFECYCLE_URL}; falling back to contiguous window v0.${FALLBACK_MIN_MINOR} .. v0.${MAX_MINOR}"
fi

# line_supported <minor> -> 0 if the line should be allowed, 1 otherwise.
# Sets REASON on rejection. Uses each line's own eolDate (fail closed).
line_supported() {
  local minor="$1" row status eol
  if $have_doc; then
    row="$(
      jq -r --arg m "$minor" '
        (.versions?)[]?
        | select(type == "object")
        | select(.version | type == "string")
        | select((.version | split(".")[0]) == "0" and (.version | split(".")[1]) == $m)
        | "\(.status)\t\(.eolDate)"
      ' <<<"$json" 2>/dev/null | head -n1
    )"
    if [ -n "$row" ]; then
      status="${row%%$'\t'*}"
      status="${status,,}"   # case-insensitive so "EOL"/"Eol" is still eol
      eol="${row#*$'\t'}"
      # Fail closed on missing/mangled fields. jq renders a JSON null/number/
      # object as text ("null", "5", "{...}"), which would pass a bare `!= "eol"`.
      # Require status to be a plain lowercase word (rejects null/number/object/
      # empty) that isn't "eol"/"null", AND a real future ISO eolDate. The eolDate
      # gate is authoritative -- any non-eol status (active/eos/future statuses)
      # with a future date is in support; a past/absent/mangled date always drops.
      # ISO dates compare lexicographically; equal to today counts as EOL.
      if [[ "$status" =~ ^[a-z]+$ ]] && [ "$status" != "eol" ] && [ "$status" != "null" ] \
        && [[ "$eol" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
        && [[ "$eol" > "$TODAY" ]]; then
        return 0
      fi
      REASON="end-of-life or unknown lifecycle (status=${status}, eol=${eol})"
      return 1
    fi
    # Freshly cut line -> allow only the SINGLE next minor above the doc's newest
    # listed 0.x line (e.g. v0.36 when the doc's highest is v0.35). Restricting to
    # max_listed+1 (rather than any minor > max_listed) bounds the blast radius if
    # the doc ever drops an EOL row instead of retaining it as `eol`: at most the
    # one just-above line can be mistaken for fresh, and a two-lines-ahead gap
    # fails closed. Requires at least one 0.x line listed (max_listed >= 0).
    if [ "$max_listed" -ge 0 ] && [ "$minor" -eq "$((max_listed + 1))" ]; then
      return 0
    fi
    if [ "$max_listed" -ge 0 ]; then
      REASON="not in lifecycle doc as an in-support line (highest listed 0.x is v0.${max_listed})"
    else
      REASON="no in-support 0.x lines in the lifecycle doc (all legacy lines are EOL)"
    fi
    return 1
  fi
  # No doc: contiguous fallback window.
  if [ "$minor" -ge "$FALLBACK_MIN_MINOR" ]; then
    return 0
  fi
  REASON="below fallback min v0.${FALLBACK_MIN_MINOR}"
  return 1
}

# --- classify each backport label ------------------------------------------
# LABELS is a JSON array of label names; a blank value means no labels.
labels_json="$LABELS"
[ -n "${labels_json//[[:space:]]/}" ] || labels_json="[]"
# Capture jq's output to a variable first: reading via `mapfile < <(jq ...)` would
# take mapfile's exit status (always 0), not jq's, so malformed input would slip
# through as an empty list instead of erroring.
if ! label_lines="$(jq -r '.[]' <<<"$labels_json" 2>/dev/null)"; then
  echo "::error::LABELS is not a valid JSON array: ${labels_json}"
  exit 1
fi
mapfile -t label_names <<<"$label_lines"

declare -a allowed=()
seen=" "
for label in "${label_names[@]}"; do
  [ -n "$label" ] || continue
  # Only 0.x lines can be legacy; strip the prefix and require a v0.<minor> tail.
  case "$label" in
    "${LABEL_PREFIX}"*) branch="${label#"${LABEL_PREFIX}"}" ;;
    *) continue ;;
  esac
  # No leading zeros: `[ -eq ]` reads decimal, so an unnormalized "036" would
  # match the v0.36 boundary yet emit a bogus "v0.036" branch target downstream.
  [[ "$branch" =~ ^v0\.(0|[1-9][0-9]*)$ ]] || {
    # v1+ (or a non v0.x branch) is monorepo era, not a legacy target.
    echo "skip ${label}: not a v0.x line (monorepo era or unrecognized)"
    continue
  }
  minor="${BASH_REMATCH[1]}"

  if [ "$minor" -gt "$MAX_MINOR" ]; then
    echo "skip ${branch}: >= v0.$((MAX_MINOR + 1)) is the monorepo era (handled by cherry-pick)"
    continue
  fi
  REASON=""
  if ! line_supported "$minor"; then
    echo "::warning::skip ${branch}: ${REASON}; not backporting"
    continue
  fi
  case "$seen" in *" ${branch} "*) continue ;; esac
  seen="${seen}${branch} "
  allowed+=("$branch")
  echo "allow ${branch}"
done

# --- emit JSON array + flag ------------------------------------------------
if [ "${#allowed[@]}" -eq 0 ]; then
  targets="[]"
  has="false"
else
  targets="$(printf '%s\n' "${allowed[@]}" | jq -R . | jq -cs .)"
  has="true"
fi

echo "targets=${targets}" >> "$GITHUB_OUTPUT"
echo "has-targets=${has}" >> "$GITHUB_OUTPUT"
echo "legacy targets: ${targets}"

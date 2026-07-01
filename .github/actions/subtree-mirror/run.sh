#!/usr/bin/env bash
set -euo pipefail

# Mirror a monorepo subtree to a downstream OSS repository.
#
# Splits SUBTREE_PREFIX out of the current repo and publishes it to BRANCH on
# the OSS remote. Two push modes:
#
#   FORCE=false  Fast-forward-only push. Creating a new branch is allowed; a
#                non-fast-forward update fails loudly. Used for release lines so
#                we never clobber a pre-merge/legacy OSS release branch.
#
#   FORCE=true   Marker-guarded force push. The OSS branch is a downstream
#                mirror, so its history is replaced on every sync. To avoid
#                destroying external contributions that were merged DIRECTLY on
#                the OSS repo (contributors do not know about the private
#                monorepo), the force push only proceeds when we can prove the
#                OSS branch holds nothing the subtree is missing:
#
#                  - OSS branch does not exist yet                  -> push
#                  - OSS branch == MARKER_REF (our last mirror)     -> push
#                  - OSS branch content == the split we would push  -> push
#                    (e.g. an external commit has since been pulled
#                     back into the subtree by sync-from-oss)
#                  - ALLOW_DIVERGENT_FORCE=true (manual re-bless)   -> push
#                  - otherwise                                      -> DIVERGED:
#                    fail closed, emit diverged=true, push nothing.
#
#                The guarded push itself is pinned with --force-with-lease to
#                the branch head we validated, so a commit that lands between
#                the check and the push fails the lease rather than being
#                destroyed. On a successful force push MARKER_REF is advanced to
#                the new split SHA so the next run can tell our own mirror apart
#                from an external commit. Equality is checked on the SHA (marker)
#                and on the tree (content); ancestry is deliberately NOT used
#                because `git subtree split` produces a synthetic history whose
#                commit graph is unrelated to the OSS repo's.
#
# Required environment variables:
#   SUBTREE_PREFIX  Path of the subtree within this repo, e.g.
#                   "staging/github.com/loft-sh/vcluster".
#   OSS_REMOTE      Pushable URL of the OSS repo (the caller builds this from a
#                   token so credentials never appear here), e.g.
#                   "https://x-access-token:TOKEN@github.com/loft-sh/vcluster.git".
#                   Tests pass a local path / file:// remote.
#   BRANCH          Target branch on the OSS repo.
#
# Optional environment variables:
#   FORCE                  "true" or "false" (default "false").
#   MARKER_REF             Ref on the OSS repo tracking the last mirrored SHA
#                          (default "refs/sync/mirror-head"). FORCE mode only.
#   ALLOW_DIVERGENT_FORCE  "true" bypasses the divergence guard (default
#                          "false"). FORCE mode only.
#   GITHUB_OUTPUT          Standard Actions output file; defaults to /dev/null
#                          so the script is runnable outside CI.

SUBTREE_PREFIX="${SUBTREE_PREFIX:?SUBTREE_PREFIX is required}"
OSS_REMOTE="${OSS_REMOTE:?OSS_REMOTE is required}"
BRANCH="${BRANCH:?BRANCH is required}"
FORCE="${FORCE:-false}"
MARKER_REF="${MARKER_REF:-refs/sync/mirror-head}"
ALLOW_DIVERGENT_FORCE="${ALLOW_DIVERGENT_FORCE:-false}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

emit() { echo "$1=$2" >> "${GITHUB_OUTPUT}"; }

# Defaults so callers can read every output unconditionally.
emit diverged false
emit pushed false

SPLIT_SHA="$(git subtree split --prefix="${SUBTREE_PREFIX}")"
emit split-sha "${SPLIT_SHA}"
echo "Subtree split SHA: ${SPLIT_SHA} -> ${BRANCH}"

if [ "${FORCE}" != "true" ]; then
  # Release lines: fast-forward only. A non-fast-forward update fails loudly.
  git push "${OSS_REMOTE}" "${SPLIT_SHA}:refs/heads/${BRANCH}"
  emit pushed true
  echo "Fast-forward push to ${BRANCH} succeeded"
  exit 0
fi

# --- FORCE mode: marker-guarded -------------------------------------------

# Current OSS branch head (empty if the branch does not exist yet).
#
# Probe existence with ls-remote so we can tell "branch absent" (exit 2) apart
# from a genuine transport/auth failure (any other non-zero). Conflating the
# two would let a transient error masquerade as a first push and permit an
# unguarded force push, so anything other than a clean absent/present answer
# fails closed. When the branch exists we fetch it to bring the commit object
# local for the tree-equality check below.
branch_ls="$(git ls-remote --exit-code --heads "${OSS_REMOTE}" "refs/heads/${BRANCH}")" && ls_status=0 || ls_status=$?
if [ "${ls_status}" -eq 0 ]; then
  REMOTE_HEAD="$(printf '%s\n' "${branch_ls}" | cut -f1)"
  git fetch --quiet "${OSS_REMOTE}" "${BRANCH}"
elif [ "${ls_status}" -eq 2 ]; then
  REMOTE_HEAD=""
else
  echo "::error::Failed to query OSS ${BRANCH} (git ls-remote exit ${ls_status}); refusing to push."
  exit 1
fi

# Last SHA we mirrored (empty if the marker does not exist yet).
if git fetch --quiet "${OSS_REMOTE}" "${MARKER_REF}" 2>/dev/null; then
  MARKER_SHA="$(git rev-parse FETCH_HEAD)"
else
  MARKER_SHA=""
fi

reason=""
if [ "${ALLOW_DIVERGENT_FORCE}" = "true" ]; then
  reason="allow-divergent-force=true (manual re-bless)"
elif [ -z "${REMOTE_HEAD}" ]; then
  reason="OSS branch ${BRANCH} does not exist yet (first push)"
elif [ -n "${MARKER_SHA}" ] && [ "${REMOTE_HEAD}" = "${MARKER_SHA}" ]; then
  reason="OSS branch matches mirror marker (no external commits)"
elif git diff --quiet "${SPLIT_SHA}" "${REMOTE_HEAD}"; then
  reason="OSS branch content already matches the subtree (reconciled)"
else
  emit diverged true
  echo "::error::OSS ${BRANCH} has commits that are not present in '${SUBTREE_PREFIX}'."
  echo "::error::Refusing to force-push: doing so would destroy external contributions made directly on the OSS repo."
  echo "::error::Run the back-sync (sync-from-oss) to pull these changes into the subtree, then retry. To override after reconciling, re-run with allow-divergent-force=true."
  echo "Divergence (OSS branch -> subtree split):"
  git --no-pager diff --stat "${REMOTE_HEAD}" "${SPLIT_SHA}" || true
  exit 1
fi

echo "Force-pushing: ${reason}"
if [ "${ALLOW_DIVERGENT_FORCE}" = "true" ]; then
  # Explicit operator override: clobber whatever is on the branch.
  git push --force "${OSS_REMOTE}" "${SPLIT_SHA}:refs/heads/${BRANCH}"
elif [ -z "${REMOTE_HEAD}" ]; then
  # First push: create the branch. A plain (non-force) push fails closed if the
  # branch was created concurrently with divergent history, rather than
  # clobbering it.
  git push "${OSS_REMOTE}" "${SPLIT_SHA}:refs/heads/${BRANCH}"
else
  # Guarded force push pinned to the head we validated above. If an external
  # commit lands on the OSS branch between that check and this push, the lease
  # fails closed instead of silently destroying it.
  git push --force-with-lease="refs/heads/${BRANCH}:${REMOTE_HEAD}" \
    "${OSS_REMOTE}" "${SPLIT_SHA}:refs/heads/${BRANCH}"
fi
# Advance the marker so the next run can distinguish our mirror from an
# external commit. Best-effort: a failed marker update must not fail the sync,
# but it does weaken the next run's guard, so surface it as a warning.
if ! git push --force "${OSS_REMOTE}" "${SPLIT_SHA}:${MARKER_REF}"; then
  echo "::warning::Pushed ${BRANCH} but failed to update marker ${MARKER_REF}; the next sync may report a false divergence."
fi
emit pushed true
echo "Force push to ${BRANCH} succeeded"

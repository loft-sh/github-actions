#!/usr/bin/env bash
set -euo pipefail

# Packages a Helm chart once per version and pushes each tarball to
# ChartMuseum. Called from the publish-helm-chart reusable workflow so the
# yq/helm/jq branching lives in a shellcheck-clean script with bats
# coverage instead of inline YAML.
#
# The helm and helm-cm-push plugin must be installed and on PATH before
# invocation; the workflow handles that.
#
# Required environment variables:
#   CHART_DIRECTORY        Path to the Helm chart directory (e.g. "chart").
#   CHART_NAME             Value written to .name in Chart.yaml. Also used
#                          to derive the packaged tarball filename
#                          (<chart-name>-<version>.tgz) and, when
#                          REPUBLISH_LATEST=true, the `helm search repo`
#                          query.
#   CHART_VERSIONS_JSON    JSON array of chart versions to publish, e.g.
#                          '["1.2.3"]' or '["0.0.0-latest","0.0.0-abc123"]'.
#                          Must be non-empty; each entry is published as a
#                          separate tarball.
#   CHART_MUSEUM_URL       ChartMuseum base URL (e.g. https://charts.loft.sh/).
#   CHART_MUSEUM_USER      ChartMuseum username.
#   CHART_MUSEUM_PASSWORD  ChartMuseum password.
#
# Optional environment variables:
#   CHART_DESCRIPTION      If set, written to .description in Chart.yaml.
#   APP_VERSION            If set, passed as --app-version to `helm package`.
#                          Not written to Chart.yaml so callers who want a
#                          decoupled Chart.yaml-level edit can do so via
#                          VALUES_EDITS (or by editing Chart.yaml directly
#                          before invoking this script).
#   VALUES_EDITS           Newline-separated `jsonpath=value` pairs applied
#                          via `yq` to <CHART_DIRECTORY>/values.yaml.
#                          Values are treated as strings. Example:
#                            product=vcluster-pro
#   REPUBLISH_LATEST       "true" to re-push the repo's latest semver after
#                          the initial push, to keep it at the top of the
#                          index. Default: "false".

: "${CHART_DIRECTORY:?CHART_DIRECTORY is required}"
: "${CHART_NAME:?CHART_NAME is required}"
: "${CHART_VERSIONS_JSON:?CHART_VERSIONS_JSON is required}"
: "${CHART_MUSEUM_URL:?CHART_MUSEUM_URL is required}"
: "${CHART_MUSEUM_USER:?CHART_MUSEUM_USER is required}"
: "${CHART_MUSEUM_PASSWORD:?CHART_MUSEUM_PASSWORD is required}"

CHART_DESCRIPTION="${CHART_DESCRIPTION:-}"
APP_VERSION="${APP_VERSION:-}"
VALUES_EDITS="${VALUES_EDITS:-}"
REPUBLISH_LATEST="${REPUBLISH_LATEST:-false}"

CHART_YAML="${CHART_DIRECTORY}/Chart.yaml"
VALUES_YAML="${CHART_DIRECTORY}/values.yaml"

if [ ! -f "${CHART_YAML}" ]; then
  echo "Error: ${CHART_YAML} does not exist" >&2
  exit 1
fi

# Parse CHART_VERSIONS_JSON into a bash array. We require jq rather than
# relying on string splitting so that versions containing metadata (e.g.
# "0.0.0-abc+build") flow through unmodified.
if ! VERSIONS_RAW=$(jq -r '.[]' <<<"${CHART_VERSIONS_JSON}" 2>/dev/null); then
  echo "Error: CHART_VERSIONS_JSON is not valid JSON: ${CHART_VERSIONS_JSON}" >&2
  exit 1
fi

VERSIONS=()
while IFS= read -r v; do
  [ -n "${v}" ] && VERSIONS+=("${v}")
done <<<"${VERSIONS_RAW}"

if [ "${#VERSIONS[@]}" -eq 0 ]; then
  echo "Error: CHART_VERSIONS_JSON must contain at least one version" >&2
  exit 1
fi

# --- Chart.yaml edits -------------------------------------------------------

echo "Setting .name = \"${CHART_NAME}\" in ${CHART_YAML}"
CHART_NAME="${CHART_NAME}" yq -i '.name = strenv(CHART_NAME)' "${CHART_YAML}"

if [ -n "${CHART_DESCRIPTION}" ]; then
  echo "Setting .description in ${CHART_YAML}"
  CHART_DESCRIPTION="${CHART_DESCRIPTION}" \
    yq -i '.description = strenv(CHART_DESCRIPTION)' "${CHART_YAML}"
fi

# --- values.yaml edits ------------------------------------------------------

if [ -n "${VALUES_EDITS}" ]; then
  if [ ! -f "${VALUES_YAML}" ]; then
    echo "Error: values-edits provided but ${VALUES_YAML} does not exist" >&2
    exit 1
  fi
  while IFS= read -r edit; do
    [ -z "${edit}" ] && continue
    if [[ "${edit}" != *=* ]]; then
      echo "Error: values-edits entry must be of the form jsonpath=value: ${edit}" >&2
      exit 1
    fi
    path="${edit%%=*}"
    value="${edit#*=}"
    echo "Setting .${path} = \"${value}\" in ${VALUES_YAML}"
    VALUES_EDIT_PATH="${path}" VALUES_EDIT_VALUE="${value}" \
      yq -i 'eval("." + strenv(VALUES_EDIT_PATH)) = strenv(VALUES_EDIT_VALUE)' \
      "${VALUES_YAML}"
  done <<<"${VALUES_EDITS}"
fi

# --- Package -----------------------------------------------------------------

PACKAGE_DIR=$(mktemp -d)
trap 'rm -rf "${PACKAGE_DIR}"' EXIT

PACKAGE_ARGS=()
if [ -n "${APP_VERSION}" ]; then
  PACKAGE_ARGS+=(--app-version "${APP_VERSION}")
fi

TARBALLS=()
for version in "${VERSIONS[@]}"; do
  echo "Packaging ${CHART_NAME} version ${version}"
  helm package "${CHART_DIRECTORY}" \
    --version "${version}" \
    "${PACKAGE_ARGS[@]}" \
    --destination "${PACKAGE_DIR}"
  TARBALLS+=("${PACKAGE_DIR}/${CHART_NAME}-${version}.tgz")
done

# --- Push --------------------------------------------------------------------

echo "Adding chartmuseum repo"
helm repo add chartmuseum "${CHART_MUSEUM_URL}" \
  --username "${CHART_MUSEUM_USER}" \
  --password "${CHART_MUSEUM_PASSWORD}"

for tarball in "${TARBALLS[@]}"; do
  echo "Pushing ${tarball} to chartmuseum"
  helm cm-push --force "${tarball}" chartmuseum
done

# --- Republish latest (optional) --------------------------------------------
#
# ChartMuseum's /index.yaml orders entries by upload time, not semver. When
# we push a patch release for an older minor line, tools that read the first
# entry (helm v2-style indexing) get the patch instead of the true latest.
# If REPUBLISH_LATEST=true, we detect the repo's highest semver and, if it
# differs from what we just pushed, re-pull and re-push it so it becomes the
# most-recently-uploaded version.

if [ "${REPUBLISH_LATEST}" = "true" ]; then
  echo "Checking whether latest semver needs to be re-pushed"
  helm repo update chartmuseum

  LATEST=$(helm search repo "chartmuseum/${CHART_NAME}" --versions -o json |
    jq -e -r '[.[].version] | sort_by(split(".") | map(tonumber? // 0)) | reverse | .[0] // empty') || {
    echo "Error: Could not determine latest version from helm repo" >&2
    exit 1
  }

  # Compare against the highest version we just published. We only ever
  # set REPUBLISH_LATEST=true from release workflows with a single version,
  # but using `sort -V | tail -n1` keeps the logic correct if a caller ever
  # passes multiple.
  PUSHED_MAX=$(printf '%s\n' "${VERSIONS[@]}" | sort -V | tail -n1)

  if [ "${LATEST}" != "${PUSHED_MAX}" ]; then
    echo "Re-pushing latest version ${LATEST} to ensure it's first in index"
    REPULL_DIR=$(mktemp -d)
    trap 'rm -rf "${PACKAGE_DIR}" "${REPULL_DIR}"' EXIT
    if ! helm pull "chartmuseum/${CHART_NAME}" --version "${LATEST}" \
      --destination "${REPULL_DIR}"; then
      echo "Error: Failed to pull chart version ${LATEST}" >&2
      exit 1
    fi
    helm cm-push --force "${REPULL_DIR}/${CHART_NAME}-${LATEST}.tgz" chartmuseum
  else
    echo "Pushed version ${PUSHED_MAX} is already the repo's latest; nothing to re-push"
  fi
fi

echo "Chart publish complete: ${CHART_NAME} ${CHART_VERSIONS_JSON}"

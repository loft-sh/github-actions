#!/usr/bin/env bash
set -euo pipefail

# Lets `go` fetch private loft-sh modules: writes a git credential helper for
# https://github.com that answers with GH_ACCESS_TOKEN.
#
# A credential helper, not an insteadOf rewrite to https://TOKEN@github.com/:
# curl 8.5.0-2ubuntu10.16 (ubuntu-24.04 runner image 20261018.339) strips
# credentials from the effective URL, git reads the difference as a redirect
# and drops the token, and the next fetch fails with "could not read Username"
# (DEVOPS-1702).
#
# Required environment:
#   GH_ACCESS_TOKEN  PAT with read access to the private repos.

: "${GH_ACCESS_TOKEN:?GH_ACCESS_TOKEN is required}"

git config --global credential.https://github.com.helper "!f() { echo username=x-access-token; echo password=${GH_ACCESS_TOKEN}; }; f"

#!/usr/bin/env bash
set -euo pipefail

readonly package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

harn run \
  --standalone \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  "$package_root/scripts/ci-runtime-evidence/cli.harn"

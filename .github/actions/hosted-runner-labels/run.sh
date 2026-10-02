#!/usr/bin/env bash
set -euo pipefail

readonly package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

HOSTED_RUNNER_LABELS_ROOT="$workspace" harn run \
  --standalone \
  --grant root=env:HOSTED_RUNNER_LABELS_ROOT,expose=HOSTED_RUNNER_LABELS_ROOT \
  --read-only-root "$package_root" \
  --read-only-root "$workspace" \
  "$package_root/scripts/hosted-runner-labels/cli.harn"

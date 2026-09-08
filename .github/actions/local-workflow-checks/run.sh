#!/usr/bin/env bash
set -euo pipefail

readonly workflow="${LOCAL_CHECK_WORKFLOW:?LOCAL_CHECK_WORKFLOW is required}"
readonly policy="${LOCAL_CHECK_POLICY:?LOCAL_CHECK_POLICY is required}"
readonly root="${LOCAL_CHECK_ROOT:?LOCAL_CHECK_ROOT is required}"
readonly package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"

args=(
  run
  --standalone
  --read-only-root "$package_root"
  --write-root "$root"
  "${package_root}/scripts/local-checks/cli.harn" --
  --workflow "$workflow"
  --policy "$policy"
  --root "$root"
)
if [[ -n "${LOCAL_CHECK_PLATFORM:-}" ]]; then
  args+=(--platform "$LOCAL_CHECK_PLATFORM")
fi
if [[ -n "${LOCAL_CHECK_BUILD_WRAPPER:-}" ]]; then
  args+=(--build-wrapper "$LOCAL_CHECK_BUILD_WRAPPER")
fi

harn "${args[@]}"

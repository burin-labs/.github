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
)

# A workflow command can only execute tools advertised on PATH if the process
# sandbox can read those tool directories. This remains subprocess-only: Harn
# filesystem builtins retain the package + repository boundary above, and the
# toolchain roots are never writable. In particular, pnpm keeps its selected
# release below PNPM_HOME, which is normally itself a PATH entry.
IFS=: read -r -a path_roots <<< "${PATH:-}"
for path_root in "${path_roots[@]}"; do
  if [[ -n "$path_root" && -d "$path_root" ]]; then
    args+=(--sandbox-read-root "$path_root")
  fi
done

args+=(
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
if [[ -n "${LOCAL_CHECK_GROUP:-}" ]]; then
  args+=(--group "$LOCAL_CHECK_GROUP")
fi

harn "${args[@]}"

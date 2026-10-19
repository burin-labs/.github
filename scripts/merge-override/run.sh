#!/usr/bin/env bash
# Dispatch one merge override step inside Harn's sandbox. Everything the step
# does after installing Harn lives in cli.harn.
set -euo pipefail

readonly package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
# Step outputs and the step summary are appended to files under the runner's
# temp directory, outside the workspace. Harn admits write roots as directories.
readonly outputs="$(dirname "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}")"
readonly summary="$(dirname "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}")"

# Harn refuses a grant whose variable is unset; a step that does not use one
# passes it empty.
variables=(
  GH_TOKEN OVERRIDE_LOG_TOKEN OVERRIDE_REPOSITORY OVERRIDE_ORGANIZATION OVERRIDE_PR
  OVERRIDE_HEAD_SHA OVERRIDE_LABEL OVERRIDE_ACTOR OVERRIDE_RUN_ID OVERRIDE_RUN_URL
  OVERRIDE_RECORD OVERRIDE_LABEL_EVENTS OVERRIDE_STEPS OVERRIDE_CANCELLED
  OVERRIDE_MERGE_COMMIT OVERRIDE_REMOVED_LABELS OVERRIDE_LOG_REPOSITORY
  GITHUB_OUTPUT GITHUB_STEP_SUMMARY
)
grants=()
for variable in "${variables[@]}"; do
  export "${variable}=${!variable:-}"
  grants+=(--grant "${variable,,}=env:${variable},expose=${variable}")
done

harn run \
  --standalone \
  --allow-process-network \
  "${grants[@]}" \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  --write-root "$outputs" \
  --write-root "$summary" \
  "$package_root/scripts/merge-override/cli.harn" -- "$@"

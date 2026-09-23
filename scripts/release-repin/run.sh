#!/usr/bin/env bash
# Dispatch the repin entrypoint inside Harn's sandbox. Everything the step does
# after installing Harn lives in cli.harn.
set -euo pipefail

readonly package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
# Step outputs are appended to a file under the runner's temp directory, which
# is outside the workspace. Harn admits write roots as directories only.
readonly outputs="$(dirname "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}")"
# An empty consumer list means every registered consumer. Harn refuses a grant
# whose variable is unset, so an omitted list is passed as an empty one.
export REPIN_CONSUMERS="${REPIN_CONSUMERS:-}"

REPIN_ROOT="$package_root" harn run \
  --standalone \
  --allow-process-network \
  --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant mode=env:REPIN_MODE,expose=REPIN_MODE \
  --grant root=env:REPIN_ROOT,expose=REPIN_ROOT \
  --grant caller=env:REPIN_CALLER,expose=REPIN_CALLER \
  --grant released=env:REPIN_RELEASED_REPOSITORY,expose=REPIN_RELEASED_REPOSITORY \
  --grant tag=env:REPIN_TAG,expose=REPIN_TAG \
  --grant consumers=env:REPIN_CONSUMERS,expose=REPIN_CONSUMERS \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  --write-root "$outputs" \
  "$package_root/scripts/release-repin/cli.harn"

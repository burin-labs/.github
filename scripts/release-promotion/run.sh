#!/usr/bin/env bash
# Dispatch the promotion entrypoint inside Harn's sandbox. Everything the step
# does after installing Harn lives in cli.harn.
set -euo pipefail

readonly package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
# Step outputs are appended to a file under the runner's temp directory, which
# is outside the workspace. Harn admits write roots as directories only.
readonly outputs="$(dirname "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}")"

harn run \
  --standalone \
  --allow-process-network \
  --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant mode=env:PROMOTE_MODE,expose=PROMOTE_MODE \
  --grant repository=env:PROMOTE_REPOSITORY,expose=PROMOTE_REPOSITORY \
  --grant sha=env:PROMOTE_SHA,expose=PROMOTE_SHA \
  --grant run_id=env:PROMOTE_RUN_ID,expose=PROMOTE_RUN_ID \
  --grant tag=env:PROMOTE_TAG,expose=PROMOTE_TAG \
  --grant directory=env:PROMOTE_DIRECTORY,expose=PROMOTE_DIRECTORY \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  --write-root "$outputs" \
  "$package_root/scripts/release-promotion/cli.harn"

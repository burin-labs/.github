#!/usr/bin/env bash
# Dispatch the consumer pin bump entrypoint inside Harn's sandbox. Everything
# the step does after installing Harn lives in cli.harn.
set -euo pipefail

readonly package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
# Step outputs are appended to a file under the runner's temp directory, which
# is outside the workspace. Harn admits write roots as directories only.
readonly outputs="$(dirname "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}")"
# Harn refuses a grant whose variable is unset, so absent optional inputs are
# passed as empty ones.
export CONSUMER_PINS_REQUESTED="${CONSUMER_PINS_REQUESTED:-}"
export GH_TOKEN="${GH_TOKEN:-}"

CONSUMER_PINS_ROOT="$package_root" harn run \
  --standalone \
  --allow-process-network \
  --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant mode=env:CONSUMER_PINS_MODE,expose=CONSUMER_PINS_MODE \
  --grant root=env:CONSUMER_PINS_ROOT,expose=CONSUMER_PINS_ROOT \
  --grant sha=env:CONSUMER_PINS_SHA,expose=CONSUMER_PINS_SHA \
  --grant requested=env:CONSUMER_PINS_REQUESTED,expose=CONSUMER_PINS_REQUESTED \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  --write-root "$outputs" \
  "$package_root/scripts/consumer-pins/cli.harn"

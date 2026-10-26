#!/usr/bin/env bash
# Dispatch the promotion entrypoint inside Harn's sandbox. Everything the step
# does after installing Harn lives in cli.harn.
set -euo pipefail

readonly package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
# Step outputs are appended to a file under the runner's temp directory, which
# is outside the workspace. Harn admits write roots as directories only.
readonly outputs="$(dirname "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}")"
# Host command captures must be allocated inside the existing workspace scope.
capture_root="$(mktemp -d "$workspace/.harn/promote-release/capture.XXXXXXXX")"
readonly capture_root
export TMPDIR="$capture_root" TMP="$capture_root" TEMP="$capture_root"
export PROMOTE_ORIGINAL_CONSUMER_CONTEXT="${PROMOTE_ORIGINAL_CONSUMER_CONTEXT:-}"
export PROMOTE_CONSUMER_REPAIR="${PROMOTE_CONSUMER_REPAIR:-}"
export PROMOTE_CONSUMER_TOKEN="${PROMOTE_CONSUMER_TOKEN:-}"
export PROMOTE_CONSUMER_REPOSITORY="${PROMOTE_CONSUMER_REPOSITORY:-}"
export PROMOTE_CONSUMER_WORKFLOW="${PROMOTE_CONSUMER_WORKFLOW:-}"
export PROMOTE_CONSUMER_READER="${PROMOTE_CONSUMER_READER:-}"
export PROMOTE_STANDALONE_HARN="${PROMOTE_STANDALONE_HARN:-false}"
export PROMOTE_QUALIFICATION_TOKEN="${PROMOTE_QUALIFICATION_TOKEN:-}"
export PROMOTE_HARN_READER_ROOT="${PROMOTE_HARN_READER_ROOT:-}"

harn run \
  --standalone \
  --allow-process-network \
  --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant mode=env:PROMOTE_MODE,expose=PROMOTE_MODE \
  --grant repository=env:PROMOTE_REPOSITORY,expose=PROMOTE_REPOSITORY \
  --grant sha=env:PROMOTE_SHA,expose=PROMOTE_SHA \
  --grant run_id=env:PROMOTE_RUN_ID,expose=PROMOTE_RUN_ID \
  --grant original_context=env:PROMOTE_ORIGINAL_CONSUMER_CONTEXT,expose=PROMOTE_ORIGINAL_CONSUMER_CONTEXT \
  --grant consumer_repair=env:PROMOTE_CONSUMER_REPAIR,expose=PROMOTE_CONSUMER_REPAIR \
  --grant consumer_token=env:PROMOTE_CONSUMER_TOKEN,expose=PROMOTE_CONSUMER_TOKEN \
  --grant consumer_repository=env:PROMOTE_CONSUMER_REPOSITORY,expose=PROMOTE_CONSUMER_REPOSITORY \
  --grant consumer_workflow=env:PROMOTE_CONSUMER_WORKFLOW,expose=PROMOTE_CONSUMER_WORKFLOW \
  --grant consumer_reader=env:PROMOTE_CONSUMER_READER,expose=PROMOTE_CONSUMER_READER \
  --grant standalone_harn=env:PROMOTE_STANDALONE_HARN,expose=PROMOTE_STANDALONE_HARN \
  --grant qualification_token=env:PROMOTE_QUALIFICATION_TOKEN,expose=PROMOTE_QUALIFICATION_TOKEN \
  --grant harn_reader_root=env:PROMOTE_HARN_READER_ROOT,expose=PROMOTE_HARN_READER_ROOT \
  --grant tag=env:PROMOTE_TAG,expose=PROMOTE_TAG \
  --grant directory=env:PROMOTE_DIRECTORY,expose=PROMOTE_DIRECTORY \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  --write-root "$outputs" \
  "$package_root/scripts/release-promotion/cli.harn"

#!/usr/bin/env bash
# Bootstrap the fixed Harn entrypoint with explicit credential and output grants.
set -euo pipefail
readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly outputs="$(dirname "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}")"
export HEAD_SHA="${HEAD_SHA:-}"
export TARGET_REPOSITORY="${TARGET_REPOSITORY:-}"
export PR_NUMBER="${PR_NUMBER:-}"
export CALLER_REPOSITORY="${CALLER_REPOSITORY:-}"
export REQUESTED_REPOSITORY="${REQUESTED_REPOSITORY:-}"
runtime_args=(--standalone)
if [ "${1:-}" != target ]; then
  : "${GH_TOKEN:?GH_TOKEN is required}"
  runtime_args+=(--allow-process-network --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN)
fi
exec harn run \
  "${runtime_args[@]}" \
  --grant caller=env:CALLER_REPOSITORY,expose=CALLER_REPOSITORY \
  --grant requested_repository=env:REQUESTED_REPOSITORY,expose=REQUESTED_REPOSITORY \
  --grant repository=env:TARGET_REPOSITORY,expose=TARGET_REPOSITORY \
  --grant pull_request=env:PR_NUMBER,expose=PR_NUMBER \
  --grant head=env:HEAD_SHA,expose=HEAD_SHA \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$root" \
  --write-root "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}" \
  --write-root "$outputs" \
  "$root/scripts/review-dispatch/cli.harn" -- "$@"

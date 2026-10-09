#!/usr/bin/env bash
# Bootstrap the fixed Harn entrypoint with explicit credential and output grants.
set -euo pipefail
readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly outputs="$(dirname "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}")"
export HEAD_SHA="${HEAD_SHA:-}"
exec harn run \
  --standalone \
  --allow-process-network \
  --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant repository=env:TARGET_REPOSITORY,expose=TARGET_REPOSITORY \
  --grant pull_request=env:PR_NUMBER,expose=PR_NUMBER \
  --grant head=env:HEAD_SHA,expose=HEAD_SHA \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$root" \
  --write-root "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}" \
  --write-root "$outputs" \
  "$root/scripts/review-dispatch/cli.harn" -- "$@"

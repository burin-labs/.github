#!/usr/bin/env bash
set -euo pipefail

readonly package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

harn run \
  --standalone \
  --allow-process-network \
  --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant repository=env:CI_RUNTIME_REPOSITORY,expose=CI_RUNTIME_REPOSITORY \
  --grant workflow=env:CI_RUNTIME_WORKFLOW,expose=CI_RUNTIME_WORKFLOW \
  --grant queries=env:CI_RUNTIME_QUERIES_JSON,expose=CI_RUNTIME_QUERIES_JSON \
  --grant output=env:CI_RUNTIME_OUTPUT,expose=CI_RUNTIME_OUTPUT \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  "$package_root/scripts/ci-runtime-evidence/cli.harn"

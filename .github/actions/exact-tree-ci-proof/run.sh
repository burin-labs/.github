#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"
readonly package_root
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
readonly step_output="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
staged_output="$(mktemp "${workspace}/.exact-tree-output.XXXXXX")"
readonly staged_output
trap 'rm -f -- "$staged_output"' EXIT

GITHUB_OUTPUT="$staged_output" harn run \
  --standalone \
  --allow-process-network \
  --grant token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant event=env:EXACT_TREE_EVENT,expose=EXACT_TREE_EVENT \
  --grant commit=env:EXACT_TREE_COMMIT,expose=EXACT_TREE_COMMIT \
  --grant repository=env:EXACT_TREE_REPOSITORY,expose=EXACT_TREE_REPOSITORY \
  --grant workflow=env:EXACT_TREE_WORKFLOW,expose=EXACT_TREE_WORKFLOW \
  --grant jobs=env:EXACT_TREE_REQUIRED_JOBS,expose=EXACT_TREE_REQUIRED_JOBS \
  --grant scope=env:EXACT_TREE_SCOPE,expose=EXACT_TREE_SCOPE \
  --grant registrar_job=env:EXACT_TREE_REGISTRAR_JOB,expose=EXACT_TREE_REGISTRAR_JOB \
  --grant registrar_step=env:EXACT_TREE_REGISTRAR_STEP,expose=EXACT_TREE_REGISTRAR_STEP \
  --grant run_id=env:EXACT_TREE_RUN_ID,expose=EXACT_TREE_RUN_ID \
  --grant attempt=env:EXACT_TREE_ATTEMPT,expose=EXACT_TREE_ATTEMPT \
  --grant cache_refresh=env:EXACT_TREE_CACHE_REFRESH,expose=EXACT_TREE_CACHE_REFRESH \
  --grant queue_writes=env:EXACT_TREE_QUEUE_WRITES_CACHE,expose=EXACT_TREE_QUEUE_WRITES_CACHE \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  "$package_root/scripts/exact-tree-proof/cli.harn"

cat -- "$staged_output" >> "$step_output"

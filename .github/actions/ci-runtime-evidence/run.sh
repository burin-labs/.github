#!/usr/bin/env bash
set -euo pipefail

readonly package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
readonly step_output="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# The runner's step-output file lives outside the workspace, beside the files
# that set environment variables and PATH for later steps. Keep it out of the
# sandbox's write roots: the collector writes its outputs to a workspace file,
# and only this script appends them to the runner's file.
staged_output="$(mktemp "${workspace}/.ci-runtime-evidence-output.XXXXXX")"
readonly staged_output
trap 'rm -f -- "$staged_output"' EXIT

GITHUB_OUTPUT="$staged_output" harn run \
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

cat -- "$staged_output" >> "$step_output"

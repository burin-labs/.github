#!/usr/bin/env bash
# Dispatch the queue-bypass guard inside Harn's sandbox. Everything the step
# does after installing Harn lives in cli.harn.
set -euo pipefail

readonly package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
# Step outputs and the step summary are appended to files under the runner's
# temp directory, outside the workspace. Harn admits write roots as directories.
readonly outputs="$(dirname "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}")"
readonly summary="$(dirname "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}")"

harn run \
  --standalone \
  --allow-process-network \
  --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant repository=env:GUARD_REPOSITORY,expose=GUARD_REPOSITORY \
  --grant pr=env:GUARD_PR,expose=GUARD_PR \
  --grant head_sha=env:GUARD_HEAD_SHA,expose=GUARD_HEAD_SHA \
  --grant label=env:GUARD_LABEL,expose=GUARD_LABEL \
  --grant main_ci_workflow=env:GUARD_MAIN_CI_WORKFLOW,expose=GUARD_MAIN_CI_WORKFLOW \
  --grant override_workflow_ref=env:GUARD_OVERRIDE_WORKFLOW_REF,expose=GUARD_OVERRIDE_WORKFLOW_REF \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --grant github_step_summary=env:GITHUB_STEP_SUMMARY,expose=GITHUB_STEP_SUMMARY \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  --write-root "$outputs" \
  --write-root "$summary" \
  "$package_root/scripts/merge-override-guard/cli.harn"

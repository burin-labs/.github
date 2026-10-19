#!/usr/bin/env bash
set -euo pipefail
package_root="$(cd "${GITHUB_ACTION_PATH:?}/../../.." && pwd)"
readonly package_root
harn run --standalone \
  --grant workspace=env:GITHUB_WORKSPACE,expose=GITHUB_WORKSPACE \
  --grant repository=env:GITHUB_REPOSITORY,expose=GITHUB_REPOSITORY \
  --grant policy=env:POLICY_PATH,expose=POLICY_PATH \
  --grant workflow=env:WORKFLOW_PATH,expose=WORKFLOW_PATH \
  --grant baseline_sha=env:BASELINE_SHA,expose=BASELINE_SHA \
  --grant baseline_state=env:BASELINE_STATE,expose=BASELINE_STATE \
  --grant baseline_file=env:BASELINE_FILE,expose=BASELINE_FILE \
  --read-only-root "$package_root" \
  --read-only-root "${GITHUB_WORKSPACE:?}" \
  --read-only-root "${RUNNER_TEMP:?}" \
  "$package_root/scripts/ci-latency/cli.harn"

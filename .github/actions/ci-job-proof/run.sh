#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"
readonly package_root
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
readonly step_output="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
staged_output="$(mktemp "${workspace}/.ci-job-proof-output.XXXXXX")"
readonly staged_output
trap 'rm -f -- "$staged_output"' EXIT

GITHUB_OUTPUT="$staged_output" harn run \
  --standalone \
  --allow-process-network \
  --grant token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant event=env:CI_JOB_PROOF_EVENT,expose=CI_JOB_PROOF_EVENT \
  --grant commit=env:CI_JOB_PROOF_COMMIT,expose=CI_JOB_PROOF_COMMIT \
  --grant repository=env:CI_JOB_PROOF_REPOSITORY,expose=CI_JOB_PROOF_REPOSITORY \
  --grant workflow=env:CI_JOB_PROOF_WORKFLOW,expose=CI_JOB_PROOF_WORKFLOW \
  --grant identities=env:CI_JOB_PROOF_IDENTITIES,expose=CI_JOB_PROOF_IDENTITIES \
  --grant merge_group_head_ref=env:CI_JOB_PROOF_MERGE_GROUP_HEAD_REF,expose=CI_JOB_PROOF_MERGE_GROUP_HEAD_REF \
  --grant registrar_job=env:CI_JOB_PROOF_REGISTRAR_JOB,expose=CI_JOB_PROOF_REGISTRAR_JOB \
  --grant registrar_step=env:CI_JOB_PROOF_REGISTRAR_STEP,expose=CI_JOB_PROOF_REGISTRAR_STEP \
  --grant run_id=env:CI_JOB_PROOF_RUN_ID,expose=CI_JOB_PROOF_RUN_ID \
  --grant attempt=env:CI_JOB_PROOF_ATTEMPT,expose=CI_JOB_PROOF_ATTEMPT \
  --grant github_output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  "$package_root/scripts/ci-job-proof/cli.harn"

cat -- "$staged_output" >> "$step_output"

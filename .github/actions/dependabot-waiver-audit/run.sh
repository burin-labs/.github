#!/usr/bin/env bash
set -euo pipefail
readonly package_root="$(cd "${GITHUB_ACTION_PATH:?}/../../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?}"
readonly output="${GITHUB_OUTPUT:?}"
readonly summary="${GITHUB_STEP_SUMMARY:?}"
staged="$(mktemp -d "${RUNNER_TEMP:?}/dependabot-waiver-audit.XXXXXX")"
readonly staged
: > "$staged/output"
: > "$staged/summary"
args=(audit --org "${DEPENDABOT_WAIVER_ORGANIZATION:?}")
if [[ "${DEPENDABOT_WAIVER_APPLY:-false}" == true ]]; then
  args+=(--apply)
fi
if GITHUB_OUTPUT="$staged/output" GITHUB_STEP_SUMMARY="$staged/summary" \
  DEPENDABOT_WAIVER_REPORT="$staged/report.json" harn run \
  --standalone \
  --allow-process-network \
  --grant token=env:GH_TOKEN,expose=GH_TOKEN \
  --grant repository=env:GITHUB_REPOSITORY,expose=GITHUB_REPOSITORY \
  --grant report=env:DEPENDABOT_WAIVER_REPORT,expose=DEPENDABOT_WAIVER_REPORT \
  --grant output=env:GITHUB_OUTPUT,expose=GITHUB_OUTPUT \
  --grant summary=env:GITHUB_STEP_SUMMARY,expose=GITHUB_STEP_SUMMARY \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  --write-root "$staged" \
  "$package_root/scripts/dependabot-waivers/cli.harn" -- "${args[@]}"; then
  result=0
else
  result=$?
fi
cat -- "$staged/output" >> "$output"
cat -- "$staged/summary" >> "$summary"
exit "$result"

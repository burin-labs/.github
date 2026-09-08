#!/usr/bin/env bash
set -euo pipefail

readonly fixture_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/local-check-contract.XXXXXX")"
cleanup() {
  find "$fixture_root" -depth -delete
}
trap cleanup EXIT

cat > "$fixture_root/workflow.yml" <<'YAML'
jobs:
  probe:
    steps:
      - name: Seeded failure
        run: exit 17
      - name: Reached after failure
        run: printf reached > reached.txt
  unwired:
    steps:
      - name: Missing job command
        run: exit 0
YAML
cat > "$fixture_root/policy.json" <<'JSON'
{"version":1,"jobs":{"probe":{}},"actions":{},"environment":{}}
JSON

set +e
output="$({
  GITHUB_ACTION_PATH="$(cd "$(dirname "$0")" && pwd)" \
    LOCAL_CHECK_WORKFLOW=workflow.yml \
    LOCAL_CHECK_POLICY=policy.json \
    LOCAL_CHECK_ROOT="$fixture_root" \
    LOCAL_CHECK_PLATFORM=linux \
    LOCAL_CHECK_BUILD_WRAPPER= \
    LOCAL_CHECK_GROUP= \
    bash "$(dirname "$0")/run.sh"
} 2>&1)"
status=$?
set -e
printf '%s\n' "$output"

test "$status" -eq 1
grep -F "FAILED probe / Seeded failure" <<< "$output"
grep -F "PASSED probe / Reached after failure" <<< "$output"
grep -F "MISSING unwired: missing job" <<< "$output"
grep -F "Checks: 1 passed, 1 failed, 1 pending" <<< "$output"
test "$(cat "$fixture_root/reached.txt")" = reached

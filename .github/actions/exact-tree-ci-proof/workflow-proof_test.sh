#!/usr/bin/env bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
proof_script="$action_dir/merge-group-proof.sh"
tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

fake_gh="$tmp_root/gh"
cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
request=runs
for arg in "$@"; do
  if [[ "$arg" == */jobs ]]; then
    request=jobs
  fi
done
if [[ "${FAKE_GH_FAIL:-}" == "$request" ]]; then
  exit 1
fi
if [[ "$request" == "jobs" ]]; then
  cat "${FAKE_GH_JOBS_RESPONSE:?}"
else
  cat "${FAKE_GH_RUNS_RESPONSE:?}"
fi
SH
chmod +x "$fake_gh"

sha=79ba0e28d76f018f5001cfd8a579d7c87c0cb6f9
required_jobs='["Rust TUI fast fmt, clippy & test","Rust TUI harn-linked clippy, test & build"]'

run_proof() {
  GH_TOKEN=test-token \
    GH_BIN="$fake_gh" \
    REQUIRED_JOBS="$required_jobs" \
    FAKE_GH_RUNS_RESPONSE="$1" \
    FAKE_GH_JOBS_RESPONSE="$2" \
    FAKE_GH_FAIL="${3:-}" \
    "$proof_script" burin-labs/burin-code ci.yml "$sha" 2>/dev/null
}

success_runs="$tmp_root/success-runs.json"
printf '%s\n' "{\"workflow_runs\":[{\"id\":123,\"head_sha\":\"$sha\",\"path\":\".github/workflows/ci.yml\",\"event\":\"merge_group\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" > "$success_runs"
success_jobs="$tmp_root/success-jobs.json"
printf '%s\n' '{"total_count":2,"jobs":[{"name":"Rust TUI fast fmt, clippy & test","status":"completed","conclusion":"success"},{"name":"Rust TUI harn-linked clippy, test & build","status":"completed","conclusion":"success"}]}' > "$success_jobs"

[[ "$(run_proof "$success_runs" "$success_jobs")" == "true" ]] || { echo "exact successful proof was rejected" >&2; exit 1; }

missing_job="$tmp_root/missing-job.json"
printf '%s\n' '{"total_count":1,"jobs":[{"name":"Rust TUI fast fmt, clippy & test","status":"completed","conclusion":"success"}]}' > "$missing_job"
[[ "$(run_proof "$success_runs" "$missing_job")" == "false" ]] || { echo "missing required job was accepted" >&2; exit 1; }

failed_job="$tmp_root/failed-job.json"
printf '%s\n' '{"total_count":2,"jobs":[{"name":"Rust TUI fast fmt, clippy & test","status":"completed","conclusion":"failure"},{"name":"Rust TUI harn-linked clippy, test & build","status":"completed","conclusion":"success"}]}' > "$failed_job"
[[ "$(run_proof "$success_runs" "$failed_job")" == "false" ]] || { echo "failed required job was accepted" >&2; exit 1; }

skipped_job="$tmp_root/skipped-job.json"
printf '%s\n' '{"total_count":2,"jobs":[{"name":"Rust TUI fast fmt, clippy & test","status":"completed","conclusion":"success"},{"name":"Rust TUI harn-linked clippy, test & build","status":"completed","conclusion":"skipped"}]}' > "$skipped_job"
[[ "$(run_proof "$success_runs" "$skipped_job")" == "false" ]] || { echo "skipped required job was accepted as proof" >&2; exit 1; }

truncated_jobs="$tmp_root/truncated-jobs.json"
printf '%s\n' '{"total_count":101,"jobs":[]}' > "$truncated_jobs"
[[ "$(run_proof "$success_runs" "$truncated_jobs")" == "false" ]] || { echo "truncated job pagination was accepted" >&2; exit 1; }

mismatch_runs="$tmp_root/mismatch-runs.json"
printf '%s\n' '{"workflow_runs":[{"id":123,"head_sha":"0000000000000000000000000000000000000000","path":".github/workflows/ci.yml","event":"merge_group","status":"completed","conclusion":"success"}]}' > "$mismatch_runs"
[[ "$(run_proof "$mismatch_runs" "$success_jobs")" == "false" ]] || { echo "mismatched SHA was accepted" >&2; exit 1; }

wrong_workflow="$tmp_root/wrong-workflow.json"
printf '%s\n' "{\"workflow_runs\":[{\"id\":123,\"head_sha\":\"$sha\",\"path\":\".github/workflows/other.yml\",\"event\":\"merge_group\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" > "$wrong_workflow"
[[ "$(run_proof "$wrong_workflow" "$success_jobs")" == "false" ]] || { echo "stale workflow proof was accepted" >&2; exit 1; }

malformed="$tmp_root/malformed.json"
printf '%s\n' '{"workflow_runs":{}}' > "$malformed"
[[ "$(run_proof "$malformed" "$success_jobs")" == "false" ]] || { echo "malformed API response did not fail closed" >&2; exit 1; }
[[ "$(run_proof "$success_runs" "$success_jobs" runs)" == "false" ]] || { echo "runs API failure did not fail closed" >&2; exit 1; }
[[ "$(run_proof "$success_runs" "$success_jobs" jobs)" == "false" ]] || { echo "jobs API failure did not fail closed" >&2; exit 1; }

[[ "$(REQUIRED_JOBS='[]' GH_TOKEN=test-token GH_BIN="$fake_gh" \
  FAKE_GH_RUNS_RESPONSE="$success_runs" FAKE_GH_JOBS_RESPONSE="$success_jobs" \
  "$proof_script" burin-labs/burin-code ci.yml "$sha" 2>/dev/null)" == "false" ]] \
  || { echo "empty REQUIRED_JOBS must fail closed" >&2; exit 1; }

echo "workflow-proof_test: ok"

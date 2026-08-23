#!/usr/bin/env bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
proof_script="$action_dir/pr-tree-proof.sh"
tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

fake_gh="$tmp_root/gh"
cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
endpoint=""
for arg in "$@"; do
  if [[ "$arg" == repos/* ]]; then
    endpoint=$arg
    break
  fi
done
case "$endpoint" in
  */pulls/*) request=pr; response=${FAKE_PR_RESPONSE:?} ;;
  */git/commits/$FAKE_GROUP_SHA) request=group_commit; response=${FAKE_GROUP_COMMIT_RESPONSE:?} ;;
  */git/commits/$FAKE_SOURCE_SHA) request=source_commit; response=${FAKE_SOURCE_COMMIT_RESPONSE:?} ;;
  */actions/workflows/*/runs) request=runs; response=${FAKE_RUNS_RESPONSE:?} ;;
  */actions/runs/*/jobs) request=jobs; response=${FAKE_JOBS_RESPONSE:?} ;;
  *) exit 2 ;;
esac
if [[ "${FAKE_GH_FAIL:-}" == "$request" ]]; then
  exit 1
fi
cat "$response"
SH
chmod +x "$fake_gh"

group_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
source_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
base_sha=cccccccccccccccccccccccccccccccccccccccc
tree_sha=dddddddddddddddddddddddddddddddddddddddd
required_jobs='["Rust TUI fast fmt, clippy & test","Rust TUI harn-linked clippy, test & build"]'

event="$tmp_root/event.json"
printf '%s\n' "{\"merge_group\":{\"head_sha\":\"$group_sha\",\"head_ref\":\"refs/heads/gh-readonly-queue/main/pr-1424-$base_sha\"}}" > "$event"
pr="$tmp_root/pr.json"
printf '%s\n' "{\"number\":1424,\"state\":\"open\",\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$source_sha\"}}" > "$pr"
group_commit="$tmp_root/group-commit.json"
printf '%s\n' "{\"sha\":\"$group_sha\",\"tree\":{\"sha\":\"$tree_sha\"}}" > "$group_commit"
source_commit="$tmp_root/source-commit.json"
printf '%s\n' "{\"sha\":\"$source_sha\",\"tree\":{\"sha\":\"$tree_sha\"}}" > "$source_commit"
runs="$tmp_root/runs.json"
printf '%s\n' "{\"workflow_runs\":[{\"id\":123,\"head_sha\":\"$source_sha\",\"path\":\".github/workflows/ci.yml\",\"event\":\"pull_request\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" > "$runs"
jobs="$tmp_root/jobs.json"
printf '%s\n' '{"total_count":2,"jobs":[{"name":"Rust TUI fast fmt, clippy & test","status":"completed","conclusion":"success"},{"name":"Rust TUI harn-linked clippy, test & build","status":"completed","conclusion":"success"}]}' > "$jobs"

run_proof() {
  GH_TOKEN=test-token \
    GH_BIN="$fake_gh" \
    REQUIRED_JOBS="$required_jobs" \
    FAKE_GROUP_SHA="$group_sha" \
    FAKE_SOURCE_SHA="$source_sha" \
    FAKE_PR_RESPONSE="${1:-$pr}" \
    FAKE_GROUP_COMMIT_RESPONSE="${2:-$group_commit}" \
    FAKE_SOURCE_COMMIT_RESPONSE="${3:-$source_commit}" \
    FAKE_RUNS_RESPONSE="${4:-$runs}" \
    FAKE_JOBS_RESPONSE="${5:-$jobs}" \
    FAKE_GH_FAIL="${6:-}" \
    "$proof_script" burin-labs/burin-code ci.yml "$group_sha" "${7:-$event}" 2>/dev/null
}

[[ "$(run_proof)" == "true" ]] || { echo "identical merge-group and source trees were not reused" >&2; exit 1; }

different_tree="$tmp_root/different-tree.json"
printf '%s\n' "{\"sha\":\"$source_sha\",\"tree\":{\"sha\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"}}" > "$different_tree"
[[ "$(run_proof "$pr" "$group_commit" "$different_tree")" == "false" ]] || { echo "different source tree was accepted" >&2; exit 1; }

wrong_event="$tmp_root/wrong-event.json"
printf '%s\n' "{\"merge_group\":{\"head_sha\":\"ffffffffffffffffffffffffffffffffffffffff\",\"head_ref\":\"refs/heads/gh-readonly-queue/main/pr-1424-$base_sha\"}}" > "$wrong_event"
[[ "$(run_proof "$pr" "$group_commit" "$source_commit" "$runs" "$jobs" "" "$wrong_event")" == "false" ]] || { echo "mismatched event SHA was accepted" >&2; exit 1; }

malformed_pr="$tmp_root/malformed-pr.json"
printf '%s\n' "{\"number\":1424,\"state\":\"closed\",\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$source_sha\"}}" > "$malformed_pr"
[[ "$(run_proof "$malformed_pr")" == "false" ]] || { echo "closed source PR was accepted" >&2; exit 1; }

[[ "$(run_proof "$pr" "$group_commit" "$source_commit" "$runs" "$jobs" pr)" == "false" ]] || { echo "PR API failure did not fail closed" >&2; exit 1; }
[[ "$(run_proof "$pr" "$group_commit" "$source_commit" "$runs" "$jobs" source_commit)" == "false" ]] || { echo "commit API failure did not fail closed" >&2; exit 1; }
[[ "$(run_proof "$pr" "$group_commit" "$source_commit" "$runs" "$jobs" runs)" == "false" ]] || { echo "workflow API failure did not fail closed" >&2; exit 1; }

echo "pr-tree-proof_test: ok"

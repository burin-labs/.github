#!/usr/bin/env bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

event_name=${EVENT_NAME:-}
repository=${REPOSITORY:-}
workflow_file=${WORKFLOW_FILE:-}
commit_sha=${COMMIT_SHA:-}
event_path=${EVENT_PATH:-}
cache_refresh_required=${CACHE_REFRESH_REQUIRED:-false}

proven=false
if [[ "$event_name" == "push" ]]; then
  if ! proven="$("$action_dir/merge-group-proof.sh" "$repository" "$workflow_file" "$commit_sha")"; then
    echo "::notice::merge-group proof helper failed; retaining full CI"
    proven=false
  fi
elif [[ "$event_name" == "merge_group" ]]; then
  if ! proven="$("$action_dir/pr-tree-proof.sh" "$repository" "$workflow_file" "$commit_sha" "$event_path")"; then
    echo "::notice::source PR-tree proof helper failed; retaining full merge-group CI"
    proven=false
  fi
fi
[[ "$proven" == "true" ]] || proven=false

reuse="$("$action_dir/gate.sh" "$event_name" "$proven" "$cache_refresh_required")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "proven=$proven" >> "$GITHUB_OUTPUT"
  echo "reuse=$reuse" >> "$GITHUB_OUTPUT"
fi
echo "exact-tree CI proof proven=$proven reuse=$reuse (cache refresh required: $cache_refresh_required)"

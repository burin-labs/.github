#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <owner/repository> <workflow-file> <commit-sha> <event>" >&2
}

fail_closed() {
  echo "::notice::workflow proof unavailable: $1" >&2
  printf 'false\n'
  exit 0
}

if [[ $# -ne 4 ]]; then
  usage
  exit 2
fi

repository=$1
workflow_file=$2
commit_sha=$3
event_name=$4
required_jobs=${REQUIRED_JOBS:-}

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  fail_closed "invalid repository identifier"
fi
if [[ ! "$workflow_file" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]]; then
  fail_closed "invalid workflow filename"
fi
if [[ ! "$commit_sha" =~ ^[0-9a-f]{40}$ ]]; then
  fail_closed "invalid commit SHA"
fi
if [[ "$event_name" != "pull_request" && "$event_name" != "merge_group" ]]; then
  fail_closed "unsupported workflow event"
fi
if [[ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  fail_closed "GitHub token is unset"
fi
if [[ -z "$required_jobs" ]]; then
  fail_closed "REQUIRED_JOBS is unset"
fi

gh_bin=${GH_BIN:-gh}
jq_bin=${JQ_BIN:-jq}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
runs_response="$tmp_dir/runs.json"
run_ids="$tmp_dir/run-ids.txt"
workflow_path=".github/workflows/${workflow_file}"

if ! "$jq_bin" -e '
  type == "array"
    and length > 0
    and all(.[]; type == "string" and . != "")
' <<<"$required_jobs" >/dev/null 2>&1; then
  fail_closed "REQUIRED_JOBS is not a non-empty JSON string array"
fi

if ! "$gh_bin" api --method GET \
  "repos/${repository}/actions/workflows/${workflow_file}/runs" \
  -f event="$event_name" \
  -f head_sha="$commit_sha" \
  -f status=success \
  -F per_page=100 > "$runs_response"; then
  fail_closed "GitHub Actions runs request failed"
fi

if ! "$jq_bin" -e '
  type == "object"
    and (.workflow_runs | type == "array")
' "$runs_response" >/dev/null 2>&1; then
  fail_closed "GitHub Actions runs response has an unexpected shape"
fi

# API filters are hints, not proof. Re-check every identity field locally.
# shellcheck disable=SC2016 # $sha, $path, and $event are jq variables.
"$jq_bin" -r \
  --arg sha "$commit_sha" \
  --arg path "$workflow_path" \
  --arg event "$event_name" '
    .workflow_runs[]
    | select(
      .head_sha == $sha
        and .path == $path
        and .event == $event
        and .status == "completed"
        and .conclusion == "success"
        and (.id | type == "number")
    )
    | .id
  ' "$runs_response" > "$run_ids"

while IFS= read -r run_id; do
  [[ "$run_id" =~ ^[0-9]+$ ]] || continue
  jobs_response="$tmp_dir/jobs-${run_id}.json"
  if ! "$gh_bin" api --method GET \
    "repos/${repository}/actions/runs/${run_id}/jobs" \
    -f filter=latest \
    -F per_page=100 > "$jobs_response"; then
    fail_closed "GitHub Actions jobs request failed"
  fi

  # Refuse truncated pagination and malformed job payloads. A green workflow
  # may have path-pruned the required jobs, so its conclusion alone is not proof.
  if ! "$jq_bin" -e '
    type == "object"
      and (.total_count | type == "number")
      and (.jobs | type == "array")
      and (.total_count == (.jobs | length))
  ' "$jobs_response" >/dev/null 2>&1; then
    fail_closed "GitHub Actions jobs response is incomplete or malformed"
  fi

  # shellcheck disable=SC2016 # $required and $response are jq variables.
  if "$jq_bin" -e --argjson required "$required_jobs" '
    . as $response
    | all(
        $required[];
        . as $name
        | any(
            $response.jobs[];
            .name == $name
              and .status == "completed"
              and .conclusion == "success"
          )
      )
  ' "$jobs_response" >/dev/null; then
    echo "::notice::reusing ${event_name} run ${run_id} for exact commit ${commit_sha} (https://github.com/${repository}/actions/runs/${run_id})" >&2
    printf 'true\n'
    exit 0
  fi
done < "$run_ids"

printf 'false\n'

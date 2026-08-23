#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <owner/repository> <workflow-file> <merge-group-sha> <event-json>" >&2
}

fail_closed() {
  echo "::notice::merge-group PR-tree proof unavailable: $1" >&2
  printf 'false\n'
  exit 0
}

if [[ $# -ne 4 ]]; then
  usage
  exit 2
fi

repository=$1
workflow_file=$2
merge_group_sha=$3
event_path=$4
action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  fail_closed "invalid repository identifier"
fi
if [[ ! "$workflow_file" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]]; then
  fail_closed "invalid workflow filename"
fi
if [[ ! "$merge_group_sha" =~ ^[0-9a-f]{40}$ ]]; then
  fail_closed "invalid merge-group SHA"
fi
if [[ ! -f "$event_path" ]]; then
  fail_closed "merge-group event payload is unavailable"
fi
if [[ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  fail_closed "GitHub token is unset"
fi

gh_bin=${GH_BIN:-gh}
jq_bin=${JQ_BIN:-jq}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# shellcheck disable=SC2016 # $sha is a jq variable.
if ! "$jq_bin" -e \
  --arg sha "$merge_group_sha" '
    type == "object"
      and (.merge_group | type == "object")
      and .merge_group.head_sha == $sha
      and (.merge_group.head_ref | type == "string")
  ' "$event_path" >/dev/null 2>&1; then
  fail_closed "event payload does not identify the exact merge-group commit"
fi

head_ref=$($jq_bin -r '.merge_group.head_ref' "$event_path")
if [[ ! "$head_ref" =~ (^|/)pr-([0-9]+)-[0-9a-f]{40}$ ]]; then
  fail_closed "merge-group head ref does not carry a canonical PR identity"
fi
pr_number=${BASH_REMATCH[2]}

pr_response="$tmp_dir/pr.json"
if ! "$gh_bin" api --method GET "repos/${repository}/pulls/${pr_number}" > "$pr_response"; then
  fail_closed "pull request lookup failed"
fi
# shellcheck disable=SC2016 # $number is a jq variable.
if ! "$jq_bin" -e \
  --argjson number "$pr_number" '
    type == "object"
      and .number == $number
      and .state == "open"
      and .base.ref == "main"
      and (.head.sha | type == "string")
      and (.head.sha | test("^[0-9a-f]{40}$"))
  ' "$pr_response" >/dev/null 2>&1; then
  fail_closed "pull request response has an unexpected identity"
fi
source_sha=$($jq_bin -r '.head.sha' "$pr_response")

merge_commit_response="$tmp_dir/merge-commit.json"
source_commit_response="$tmp_dir/source-commit.json"
if ! "$gh_bin" api --method GET \
  "repos/${repository}/git/commits/${merge_group_sha}" > "$merge_commit_response"; then
  fail_closed "merge-group commit lookup failed"
fi
if ! "$gh_bin" api --method GET \
  "repos/${repository}/git/commits/${source_sha}" > "$source_commit_response"; then
  fail_closed "source commit lookup failed"
fi

commit_shape='type == "object"
  and (.sha | type == "string")
  and (.tree.sha | type == "string")
  and (.tree.sha | test("^[0-9a-f]{40}$"))'
if ! "$jq_bin" -e --arg sha "$merge_group_sha" \
  "${commit_shape} and .sha == \$sha" "$merge_commit_response" >/dev/null 2>&1; then
  fail_closed "merge-group commit response has an unexpected identity"
fi
if ! "$jq_bin" -e --arg sha "$source_sha" \
  "${commit_shape} and .sha == \$sha" "$source_commit_response" >/dev/null 2>&1; then
  fail_closed "source commit response has an unexpected identity"
fi

merge_tree=$($jq_bin -r '.tree.sha' "$merge_commit_response")
source_tree=$($jq_bin -r '.tree.sha' "$source_commit_response")
if [[ "$merge_tree" != "$source_tree" ]]; then
  fail_closed "merge group tree ${merge_tree} differs from PR source tree ${source_tree}"
fi

proven=false
if ! proven=$(
  "$action_dir/workflow-proof.sh" \
    "$repository" "$workflow_file" "$source_sha" pull_request
); then
  fail_closed "source PR workflow proof helper failed"
fi
if [[ "$proven" != "true" ]]; then
  printf 'false\n'
  exit 0
fi

echo "::notice::reusing source PR #${pr_number} proof because merge-group ${merge_group_sha} has exact tree ${merge_tree}" >&2
printf 'true\n'

#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <event-name> <merge-group-proven> <cache-refresh-required>" >&2
  exit 2
fi

event_name=$1
merge_group_proven=$2
cache_refresh_required=$3

for value in "$merge_group_proven" "$cache_refresh_required"; do
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    echo "proof gate requires closed boolean inputs" >&2
    exit 1
  fi
done

# Merge groups never write the Rust cache, but a cache-contract change still
# needs the jobs to run so the next landing push can publish the new key.
# Source PRs produce proof; they never consume it.
if [[ ("$event_name" == "push" || "$event_name" == "merge_group")
  && "$merge_group_proven" == "true"
  && "$cache_refresh_required" == "false" ]]; then
  printf 'true\n'
else
  printf 'false\n'
fi

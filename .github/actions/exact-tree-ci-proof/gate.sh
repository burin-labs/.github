#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <event-name> <merge-group-proven> <cache-refresh-required> <merge-group-writes-cache>" >&2
  exit 2
fi

event_name=$1
merge_group_proven=$2
cache_refresh_required=$3
merge_group_writes_cache=$4

for value in "$merge_group_proven" "$cache_refresh_required" "$merge_group_writes_cache"; do
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    echo "proof gate requires closed boolean inputs" >&2
    exit 1
  fi
done

if [[ "$merge_group_proven" != "true" ]]; then
  printf 'false\n'
  exit 0
fi

case "$event_name" in
  push)
    if [[ "$cache_refresh_required" == "true" ]]; then
      printf 'false\n'
    else
      printf 'true\n'
    fi
    ;;
  merge_group)
    # Merge groups that never persist a cache produce nothing if they rebuild.
    # An exact-tree proof already includes the cache-contract files. Keep the
    # jobs only when this event is itself a writer.
    if [[ "$merge_group_writes_cache" == "true" && "$cache_refresh_required" == "true" ]]; then
      printf 'false\n'
    else
      printf 'true\n'
    fi
    ;;
  *)
    printf 'false\n'
    ;;
esac

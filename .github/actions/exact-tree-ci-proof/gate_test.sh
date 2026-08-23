#!/usr/bin/env bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gate="$action_dir/gate.sh"

[[ "$($gate push true false)" == "true" ]] || { echo "exact proof with unchanged cache contract must be reusable" >&2; exit 1; }
[[ "$($gate push true true)" == "false" ]] || { echo "cache-contract change must retain the writer" >&2; exit 1; }
[[ "$($gate push false false)" == "false" ]] || { echo "missing proof must retain full CI" >&2; exit 1; }
[[ "$($gate merge_group true false)" == "true" ]] || { echo "exact-tree PR proof must be reusable by a merge group" >&2; exit 1; }
[[ "$($gate merge_group true true)" == "false" ]] || { echo "merge-group cache-contract change must retain the writer" >&2; exit 1; }
[[ "$($gate pull_request true false)" == "false" ]] || { echo "source PRs must produce rather than consume proof" >&2; exit 1; }

if "$gate" push ambiguous false >/dev/null 2>&1; then
  echo "ambiguous proof input must fail closed" >&2
  exit 1
fi

echo "gate_test: ok"

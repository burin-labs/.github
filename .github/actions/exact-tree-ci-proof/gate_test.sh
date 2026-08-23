#!/usr/bin/env bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gate="$action_dir/gate.sh"

[[ "$($gate push true false false)" == "true" ]] || { echo "exact proof with unchanged cache contract must be reusable on push" >&2; exit 1; }
[[ "$($gate push true true false)" == "false" ]] || { echo "cache-contract change must retain the push writer" >&2; exit 1; }
[[ "$($gate push false false false)" == "false" ]] || { echo "missing proof must retain full CI" >&2; exit 1; }
[[ "$($gate merge_group true false false)" == "true" ]] || { echo "exact-tree PR proof must be reusable by a restore-only merge group" >&2; exit 1; }
[[ "$($gate merge_group true true false)" == "true" ]] || { echo "restore-only merge group must reuse even when the cache contract changed" >&2; exit 1; }
[[ "$($gate merge_group true true true)" == "false" ]] || { echo "cache-writing merge group must retain the writer on a cache-contract change" >&2; exit 1; }
[[ "$($gate merge_group true false true)" == "true" ]] || { echo "cache-writing merge group with unchanged contract must reuse" >&2; exit 1; }
[[ "$($gate pull_request true false false)" == "false" ]] || { echo "source PRs must produce rather than consume proof" >&2; exit 1; }

if "$gate" push ambiguous false false >/dev/null 2>&1; then
  echo "ambiguous proof input must fail closed" >&2
  exit 1
fi

echo "gate_test: ok"

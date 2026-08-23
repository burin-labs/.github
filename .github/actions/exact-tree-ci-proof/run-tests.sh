#!/usr/bin/env bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$action_dir/gate_test.sh"
"$action_dir/workflow-proof_test.sh"
"$action_dir/pr-tree-proof_test.sh"
echo "exact-tree-ci-proof: all tests passed"

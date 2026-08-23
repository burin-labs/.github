#!/usr/bin/env bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$action_dir/workflow-proof.sh" "$@" merge_group

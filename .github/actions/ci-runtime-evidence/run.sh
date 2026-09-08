#!/usr/bin/env bash
set -euo pipefail

readonly package_root="$(cd "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}/../../.." && pwd)"
readonly workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-${workspace}/.harn/gh-config}"

harn run \
  --standalone \
  --grant gh_token=env:GH_TOKEN,expose=GH_TOKEN,for=gh \
  --grant gh_config=env:GH_CONFIG_DIR,expose=GH_CONFIG_DIR,for=gh \
  --read-only-root "$package_root" \
  --write-root "$workspace" \
  "$package_root/scripts/ci-runtime-evidence/cli.harn"

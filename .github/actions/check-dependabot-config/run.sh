#!/usr/bin/env bash
set -euo pipefail
runtime="${DEPENDABOT_CHECK_HARN_BINARY:-harn}"
if [[ "${DEPENDABOT_CHECK_OWNS_RUNTIME:-0}" == "1" ]]; then
  if [[ ! "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ || ! "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]]; then
    echo "::error::checker runtime requires the producing run identity" >&2
    exit 2
  fi
  install_dir="${RUNNER_TEMP:?}/dependabot-config-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
  if [[ ! -d "$install_dir" || -L "$install_dir" ]]; then
    echo "::error::checker runtime requires its own physical install directory" >&2
    exit 2
  fi
  case "$runtime" in
    "$install_dir/harn"|"$install_dir/harn.exe")
      trap 'rm -f -- "$runtime"' EXIT
      ;;
    *) echo "::error::checker runtime is outside its private install directory" >&2; exit 2 ;;
  esac
fi
"$runtime" run --read-only-root "${DEPENDABOT_CHECK_ROOT:?}" \
  "$GITHUB_ACTION_PATH/../../../scripts/dependabot-config/cli.harn"

#!/usr/bin/env bash
set -euo pipefail
runtime="${DEPENDABOT_CHECK_HARN_BINARY:-harn}"
if [[ "${DEPENDABOT_CHECK_OWNS_RUNTIME:-0}" == "1" ]]; then
  case "$runtime" in
    "${RUNNER_TEMP:?}"/dependabot-config-*/harn|"${RUNNER_TEMP:?}"/dependabot-config-*/harn.exe)
      trap 'rm -f -- "$runtime"' EXIT
      ;;
    *) echo "::error::checker runtime is outside its private install directory" >&2; exit 2 ;;
  esac
fi
"$runtime" run --read-only-root "${DEPENDABOT_CHECK_ROOT:?}" \
  "$GITHUB_ACTION_PATH/../../../scripts/dependabot-config/cli.harn"

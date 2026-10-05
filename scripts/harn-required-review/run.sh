#!/usr/bin/env bash
# Bootstrap only: validate the fixed Harn entrypoint, then dispatch its profile.
set -euo pipefail
if (($#)); then
  echo 'review-rule launcher accepts no arbitrary command arguments' >&2
  exit 2
fi
readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly runtime="$(command -v harn)"
readonly plan="$(mktemp "${TMPDIR:-/tmp}/harn-review-launch.XXXXXX")"
trap 'rm -f "$plan"' EXIT
"$runtime" run --standalone --read-only-root "$HOME/.local/share/gh-budget" \
  "$root/scripts/harn-required-review/launch-plan.harn" -- "$root" > "$plan"
args=()
while IFS= read -r argument; do args+=("$argument"); done < "$plan"
rm -f "$plan"
trap - EXIT
# This launcher is for reviewed deterministic control code, never model runs.
export GH_BUDGET_STATE_DIR="$HOME/.local/state/gh-budget"
export GH_BUDGET_AGENT=1
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
unset GH_BUDGET_DISABLE GH_ADMIN_ACTION GH_BUDGET_REAL_GH GH_HOST GITHUB_TOKEN
exec "$runtime" "${args[@]}"

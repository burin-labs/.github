#!/usr/bin/env bash
# Bootstrap only: validate the fixed Harn entrypoint, then dispatch its profile.
set -euo pipefail
if (($#)); then
  echo 'review-rule launcher accepts no arbitrary command arguments' >&2
  exit 2
fi
readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly runtime="$(command -v harn)"
readonly home_canonical="$(cd "$HOME" && pwd -P)"
export REVIEW_CONTROL_HOME_CANONICAL="$home_canonical"
export REVIEW_CONTROL_BUNDLE_CANONICAL="$(cd "$home_canonical/.local/share/gh-budget" 2>/dev/null && pwd -P || true)"
export REVIEW_CONTROL_LEDGER_CANONICAL="$(cd "$home_canonical/.local/state/gh-budget" 2>/dev/null && pwd -P || true)"
cd "$root"
readonly plan="$(mktemp "${TMPDIR:-/tmp}/harn-review-launch.XXXXXX")"
trap 'rm -f "$plan"' EXIT
"$runtime" run --standalone "$root/scripts/harn-required-review/launch-plan.harn" \
  -- "$root" preflight > "$plan"
planner_args=(run --standalone)
while IFS= read -r argument; do planner_args+=("$argument"); done < "$plan"
"$runtime" "${planner_args[@]}" \
  "$root/scripts/harn-required-review/launch-plan.harn" -- "$root" dispatch > "$plan"
args=()
{
  IFS= read -r ledger_root
  IFS= read -r command_path
  while IFS= read -r argument; do args+=("$argument"); done
} < "$plan"
rm -f "$plan"
trap - EXIT
# This launcher is for reviewed deterministic control code, never model runs.
export GH_BUDGET_STATE_DIR="$ledger_root"
export GH_BUDGET_AGENT=1
export PATH="$command_path"
unset GH_BUDGET_DISABLE GH_ADMIN_ACTION GH_BUDGET_REAL_GH GH_BUDGET_PRINT_REAL GH_HOST GITHUB_TOKEN
exec "$runtime" "${args[@]}"

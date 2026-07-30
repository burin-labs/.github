#!/usr/bin/env bash
#
# ci-routing.sh - move this org's CI between self-hosted and GitHub-hosted
# runners, and show which mechanism is currently deciding.
#
#   ci-routing.sh status                 report every lever, and what it implies
#   ci-routing.sh hosted-only [lanes]    retire self-hosted routing (default: all)
#   ci-routing.sh self-hosted            offer self-hosted routing again
#
# `lanes` is `all` or a comma list of linux, linux_big, macos, windows.
#
#   ci-routing.sh hosted-only            # everything hosted
#   ci-routing.sh hosted-only macos      # free the Macs, keep Linux self-hosted
#
# This writes exactly one thing: the organization variable
# `CI_SELFHOSTED_DISABLED`, which .github/workflows/runner-availability.yml
# owns. Every caller already gates `runs-on` on that detector's outputs, so one
# variable moves every repo's every gated lane. `self-hosted` clears it, which
# is why no snapshot file is needed to reverse this - "off" is the absence of
# the variable, not a value to restore.
#
# Deliberately NOT done here:
#
#   * Runner label surgery. Invisible from the workflow source, strands jobs
#     that hardcode self-hosted labels with no availability gate, and some
#     runners in this org registered `self-hosted`/`Linux`/`X64` as *custom*
#     rather than read-only labels, so a rewrite can make one unaddressable.
#   * Stopping runner services. That is a machine-local measurement concern,
#     already owned by burin-code's actions-runner-window-guard.sh, which stops
#     services for an eval window and restores them on exit.
#
# Why you would reach for this: hosted Actions minutes are a monthly
# use-it-or-lose-it grant, and public repositories get them free outright. So
# self-hosted routing is not a cost saving - it spends the local boxes' CPU,
# contending with whatever eval work is running on them.

set -euo pipefail

ORG="${CI_ROUTING_ORG:-burin-labs}"
SWITCH=CI_SELFHOSTED_DISABLED

# Per-repo variables that predate the org switch and can still override it or
# stack with it. Reported by `status` so a surprising routing decision is
# traceable, never written by this script: each belongs to its own repo.
REPO_OVERRIDES=(
  "harn:HARN_CI_DISABLE_SELFHOSTED_LINUX"
  "harn:HARN_CI_DISABLE_BLACKSMITH_LINUX"
  "burin-code:BURIN_CI_DISABLE_BLACKSMITH_LINUX"
  "harn-cloud:HARN_CLOUD_CI_DISABLE_BLACKSMITH_RUST"
)

die() { echo "error: $*" >&2; exit 1; }

# A missing variable is a 404, and `gh api` prints the error body to STDOUT
# before exiting nonzero. Capture it so the body cannot be mistaken for a value.
org_var() {
  local out
  out="$(gh api "/orgs/$ORG/actions/variables/$SWITCH" --jq '.value' 2>/dev/null)" || out=""
  printf '%s' "$out"
}

repo_var() {
  local out
  out="$(gh api "/repos/$ORG/$1/actions/variables/$2" --jq '.value' 2>/dev/null)" || out="unset"
  printf '%s' "$out"
}

# Expand the switch value the same way the detector does, so `status` reports
# what CI will actually conclude rather than re-deriving it differently here.
# `linux` implies `linux_big`: the big lane is a strict subset of the pool.
expand_lanes() {
  local raw="$1" out="" token
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    "" | none | false) return 0 ;;
    all | true) echo "linux linux_big macos windows"; return 0 ;;
  esac
  for token in $(printf '%s' "$raw" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
    case "$token" in
      all | true) out="$out linux linux_big macos windows" ;;
      none | false) : ;;
      linux) out="$out linux linux_big" ;;
      linux_big | macos | windows) out="$out $token" ;;
      *) echo "warning: unknown lane '$token'" >&2 ;;
    esac
  done
  printf '%s' "$out" | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd' ' -
}

cmd_status() {
  local value lanes
  value="$(org_var)"
  lanes="$(expand_lanes "$value")"

  echo "Org switch  $SWITCH = ${value:-<unset>}"
  if [ -z "$lanes" ]; then
    echo "            self-hosted routing is OFFERED; capacity decides each lane"
  else
    echo "            retired lanes: $lanes"
    echo "            gated jobs on those lanes route to GitHub-hosted runners"
  fi

  echo
  echo "Per-repo overrides (reported only; each belongs to its own repo):"
  local pair repo name
  for pair in "${REPO_OVERRIDES[@]}"; do
    repo="${pair%%:*}"; name="${pair##*:}"
    printf '    %-46s %s\n' "$repo/$name" "$(repo_var "$repo" "$name")"
  done

  echo
  echo "Self-hosted fleet (vendor-managed groups excluded: they register one"
  echo "ephemeral runner per job and never deregister):"
  # `--slurp` cannot be combined with `--jq`, so page objects are collected raw
  # and unwrapped afterwards. Groups are enumerated by id and deduplicated by
  # runner id, because this org has two distinct groups both named "Default".
  local runners
  runners="$(for group in $(gh api --paginate "/orgs/$ORG/actions/runner-groups" \
      --jq '.runner_groups[] | select(.name | startswith("Blacksmith") | not) | .id'); do
    gh api --paginate --slurp "/orgs/$ORG/actions/runner-groups/$group/runners?per_page=100"
  done | jq -s 'flatten | map(.runners) | flatten | unique_by(.id)')"
  echo "$runners" | jq -r 'sort_by(.name)[]
    | "    \(.name)\(" " * ([1, 18 - (.name | length)] | max))\(.status) \(if .busy then "busy" else "idle" end)  \([.labels[].name] | join(" "))"'

  echo
  # Keep this note honest about which job is deliberate. It previously said "the
  # latter", attributing the deliberate choice to `terraform`, and listed
  # burin-code's eval-golden-selftest as ungated after burin-code#5579 had
  # already gated it on `selfhosted_disabled`. A note that misdescribes current
  # behaviour is not cosmetic: reading one is what let a stale detector pin and a
  # fail-closed detector fork both survive unnoticed.
  echo "Note: a job that hardcodes self-hosted labels with no gate ignores this"
  echo "      switch entirely - it queues instead of falling back, up to the 24h"
  echo "      ceiling. On harn-cloud main: \`docker\` (deliberate - it needs the"
  echo "      pool's shared Docker daemon, so it must outlive a hosted-minutes"
  echo "      outage) and \`terraform\` (incidental - fmt/tflint/validate need"
  echo "      nothing self-hosted). Tracked in burin-labs/harn-cloud#1397."
  echo "      A job that is self-hosted by nature should gate on the detector's"
  echo "      \`selfhosted_disabled\` output, never on its per-OS availability"
  echo "      outputs, which also go false when the fleet is merely busy."
}

cmd_hosted_only() {
  local lanes="${1:-all}" expanded
  expanded="$(expand_lanes "$lanes")"
  [ -n "$expanded" ] || die "'$lanes' expands to no lanes; use all, or a comma list of linux, linux_big, macos, windows"
  gh variable set "$SWITCH" --org "$ORG" --visibility all --body "$lanes" >/dev/null
  echo "$SWITCH = $lanes  (retires: $expanded)"
  echo "Reverse with: $(basename "$0") self-hosted"
}

cmd_self_hosted() {
  gh variable delete "$SWITCH" --org "$ORG" >/dev/null 2>&1 \
    && echo "$SWITCH cleared; self-hosted routing offered again" \
    || echo "$SWITCH was already unset; self-hosted routing was already offered"
  local pinned
  pinned="$(repo_var harn HARN_CI_DISABLE_SELFHOSTED_LINUX)"
  if [ "$pinned" = true ]; then
    echo
    echo "warning: harn/HARN_CI_DISABLE_SELFHOSTED_LINUX is still true, which pins"
    echo "         harn's Linux CI to hosted regardless of this switch. Clear it with:"
    echo "           gh variable set HARN_CI_DISABLE_SELFHOSTED_LINUX --body false -R $ORG/harn"
  fi
}

case "${1:-status}" in
  status)      cmd_status ;;
  hosted-only) cmd_hosted_only "${2:-all}" ;;
  self-hosted) cmd_self_hosted ;;
  *)           die "unknown command '$1'. Use: status | hosted-only [lanes] | self-hosted" ;;
esac

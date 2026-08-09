#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy_path="${RUNNER_FLEET_POLICY_PATH:-$repo_root/.github/runner-fleet.json}"
mode="${1:-}"

organization="$(jq -er '.organization | select(type == "string" and length > 0)' "$policy_path")"
jq -e '
  .schema_version == 1
  and (.probe_interval_seconds | type == "number" and . >= 30 and . <= 300)
  and (.expected_runners | type == "array" and length > 0)
  and (.expected_runners | all(type == "string" and length > 0))
  and ((.expected_runners | unique | length) == (.expected_runners | length))
' "$policy_path" >/dev/null

snapshot() {
  gh api --paginate --slurp \
    "/orgs/${organization}/actions/runners?per_page=100" \
    | jq -c --slurpfile policy "$policy_path" '
        [.[].runners[]
          | select(.name as $name | $policy[0].expected_runners | index($name))
          | {name, status, busy}
        ]
        | unique_by(.name)
        | sort_by(.name)
      '
}

evaluate() {
  local first_path="${1:-}"
  local second_path="${2:-}"
  [[ -f "$first_path" && -f "$second_path" ]] || {
    echo "usage: $0 evaluate <first-snapshot.json> <second-snapshot.json>" >&2
    exit 64
  }

  local report
  report="$(jq -cn \
    --slurpfile policy "$policy_path" \
    --slurpfile first "$first_path" \
    --slurpfile second "$second_path" '
      def state($items; $name):
        ($items | map(select(.name == $name)) | first)
        // {name: $name, status: "missing", busy: false};
      [ $policy[0].expected_runners[] as $name
        | {
            name: $name,
            first: state($first[0]; $name),
            second: state($second[0]; $name)
          }
      ] as $runners
      | [ $runners[]
          | select(.first.status != "online" and .second.status != "online")
        ] as $unhealthy
      | {
          schema_version: "burin.runner_fleet_health.v1",
          organization: $policy[0].organization,
          probe_interval_seconds: $policy[0].probe_interval_seconds,
          expected_count: ($policy[0].expected_runners | length),
          first_observed_count: ($first[0] | length),
          second_observed_count: ($second[0] | length),
          ok: ($unhealthy | length == 0),
          unhealthy: $unhealthy,
          runners: $runners
        }
    ')"
  printf '%s\n' "$report"
  jq -e '.ok' >/dev/null <<<"$report"
}

case "$mode" in
  snapshot)
    [[ -z "${2:-}" ]] || { echo "usage: $0 snapshot" >&2; exit 64; }
    snapshot
    ;;
  evaluate)
    [[ -z "${4:-}" ]] || { echo "usage: $0 evaluate <first-snapshot.json> <second-snapshot.json>" >&2; exit 64; }
    evaluate "${2:-}" "${3:-}"
    ;;
  *)
    echo "usage: $0 snapshot | evaluate <first-snapshot.json> <second-snapshot.json>" >&2
    exit 64
    ;;
esac

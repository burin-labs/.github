#!/usr/bin/env bash
# Test for check.sh. Stubs `gh pr view` with canned pull request JSON so every
# branch is exercised without a network call. Run: bash check_test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$STUB_PR_JSON"
STUB
chmod +x "$stub_dir/gh"
PATH="$stub_dir:$PATH"
export PATH

failures=0
pass_count=0

# run_case <name> <expected exit> <title> <isDraft> <body> [PR_NUMBER override]
run_case() {
  local name="$1" expected="$2" title="$3" draft="$4" body="$5"
  local pr_number="${6-42}"
  STUB_PR_JSON="$(jq -n --arg t "$title" --arg b "$body" --argjson d "$draft" \
    '{title:$t, body:$b, isDraft:$d}')"
  export STUB_PR_JSON
  local out status
  out="$(REPO=burin-labs/example PR_NUMBER="$pr_number" AREAS='CI|Actions|Docs|Harn bridge' \
    bash "$here/check.sh" 2>&1)"
  status=$?
  if [[ "$status" -eq "$expected" ]]; then
    pass_count=$((pass_count + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: ${name}"
    echo "  expected exit ${expected}, got ${status}"
    echo "  output: ${out}"
  fi
}

good_body='Fixes the release runner health check reporting unknown for any runner that finished a job in the last minute, because the liveness probe read a stale cache entry. Fleet dashboards flapped during every deploy window. The risk is that a runner which is genuinely down reads as live for one cache interval.'

# The org template as it ships: comments plus one heading, nothing else.
unfilled_template="$(cat "$here/../../pull_request_template.md")"

checklist_only='## What changed

## Checklist

- [ ] The title follows the convention.
- [ ] Secrets are redacted.

Closes #123 items: 1, 2

🤖 Generated with [Claude Code](https://claude.com/claude-code)'

run_case "well-formed title and body passes" 0 '[CI] Fix the flaky release runner probe' false "$good_body"
run_case "multi-word area passes" 0 '[Harn bridge] Recover the settling response' false "$good_body"
run_case "missing bracket tag fails" 1 'Fix the flaky release runner probe' false "$good_body"
run_case "unlisted area fails" 1 '[Kitchen] Fix the flaky release runner probe' false "$good_body"
run_case "lowercase first word fails" 1 '[CI] fix the flaky release runner probe' false "$good_body"
run_case "trailing period fails" 1 '[CI] Fix the flaky release runner probe.' false "$good_body"
run_case "release title is exempt" 0 'Release v0.10.126' false ''
run_case "dependabot chore title is exempt" 0 'chore(deps): bump actions/checkout from 4 to 5' false ''
run_case "dependabot build title is exempt" 0 'build(deps-dev): bump eslint from 9 to 10' false ''
run_case "recovered WIP draft is exempt" 0 'WIP (recovered): whatever' true ''
run_case "empty body fails" 1 '[CI] Fix the flaky release runner probe' false ''

# The negative control the previous version of this check got wrong: an
# author who opens a PR and touches nothing must fail, not pass.
run_case "unedited template body fails" 1 '[CI] Fix the flaky release runner probe' false "$unfilled_template"
run_case "headings and checklist only fails" 1 '[CI] Fix the flaky release runner probe' false "$checklist_only"

# A merge queue or push event carries no PR number. Skipping there is what
# keeps this check from deadlocking a queue it was never meant to gate.
run_case "absent PR number skips instead of failing" 0 '[CI] Fix the flaky release runner probe' false "$good_body" ''

echo
if [[ "$failures" -eq 0 ]]; then
  echo "check.sh: ${pass_count} cases passed."
else
  echo "check.sh: ${failures} case(s) failed, ${pass_count} passed."
  exit 1
fi

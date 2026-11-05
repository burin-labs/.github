#!/usr/bin/env bash
#
# reusable-pin-drift.sh - report stale reusable workflow pins and callers that
# read outputs their exact pin does not declare.
#
#   reusable-pin-drift.sh report              human-readable table
#   reusable-pin-drift.sh report --json       machine-readable rows
#   reusable-pin-drift.sh sync-issue          file/update/close the drift issue
#
# Alongside the contract verdicts, every full-SHA pin gets a MEASURED staleness
# record: the commits to the target since the pin that touched the workflow or
# any path it checks out or runs at its own ref. Paths are derived from the
# workflow by scripts/reusable_pin_contract.rb, plus the explicit table in
# scripts/reusable-pin-execution-paths.json. The commits are read from a local
# full-history clone of this repository (PIN_DRIFT_GIT_DIR, default: the clone
# holding this script).
#
# Why this exists: a full-40-character SHA pin satisfies every "is it pinned"
# guard in the org (harn's `make lint-actions-source`, this repo's own review)
# while pointing at a revision `main` moved past weeks ago. Those guards check
# pin SHAPE; nothing checked pin FRESHNESS. `harn` sat pinned at 3893a4d8 while
# runner-availability.yml gained the kill-switch output and the duplicate-group
# union fix, so its Linux lanes reported `false` on every run with every gate
# green. It surfaced only because someone read the pin by hand. See
# burin-labs/harn#5803.
#
# This repo is the only place that can run this check: it owns the reusable
# workflows, so it is the only one that knows what "current" is. A consumer
# cannot detect its own staleness without reaching in here anyway.
#
# ---------------------------------------------------------------------------
# Drift is CONTENT drift, not SHA drift
# ---------------------------------------------------------------------------
#
# "Pinned SHA != main HEAD" is the wrong test. Every commit to this repo - a
# README typo, a change to an unrelated workflow - would make every consumer
# "behind" while the workflow they actually call is byte-identical. A report
# that cries drift on every push gets muted, and a muted detector is worse than
# none because it also launders the real cases.
#
# So each consumer is classified by comparing the referenced FILE's blob at the
# pinned ref against its blob at the target ref. A pin that trails main but
# resolves to identical content is reported as informational, never actionable.
#
# ---------------------------------------------------------------------------
# What this deliberately does NOT check
# ---------------------------------------------------------------------------
#
# Whether a `uses:` is pinned to a SHA at all, rather than to a tag or branch.
# harn's `make lint-actions-source` already owns that, and two owners for one
# check means two places to update and a disagreement to adjudicate. A non-SHA
# ref is still REPORTED here (as `unpinned-ref`) because ignoring it would let a
# consumer disappear from the census entirely, but it is never counted as drift
# and this script never tells you to fix it.

set -euo pipefail

ORG="${PIN_DRIFT_ORG:-burin-labs}"
POLICY_REPO="${PIN_DRIFT_POLICY_REPO:-.github}"
TARGET_REF="${PIN_DRIFT_TARGET_REF:-main}"
ISSUE_TITLE="${PIN_DRIFT_ISSUE_TITLE:-Reusable workflow pin or output contract drift detected}"
# Stable machine marker so the issue is re-findable without depending on a label
# existing, on the title surviving an edit, or on search indexing being current.
ISSUE_MARKER="<!-- reusable-pin-drift:report -->"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CONTRACT_HELPER="${SCRIPT_DIR}/reusable_pin_contract.rb"
# Not GIT_DIR: git itself reads that name from the environment.
POLICY_GIT_DIR="${PIN_DRIFT_GIT_DIR:-${SCRIPT_DIR}/..}"

OUTPUT_JSON=false
WRITE_ISSUE=false
COMMAND=""

die() { echo "error: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//;s/^#$//' | sed '$d'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    report | sync-issue) COMMAND="$1" ;;
    # Pure test seams take positional arguments, so stop parsing and leave them
    # in place.
    classify)
      COMMAND="classify"
      shift
      break
      ;;
    classify-outputs)
      COMMAND="classify-outputs"
      shift
      break
      ;;
    render-staleness)
      COMMAND="render-staleness"
      shift
      break
      ;;
    --json) OUTPUT_JSON=true ;;
    --target-ref)
      shift
      [ $# -gt 0 ] || die "--target-ref needs a value"
      TARGET_REF="$1"
      ;;
    --org)
      shift
      [ $# -gt 0 ] || die "--org needs a value"
      ORG="$1"
      ;;
    -h | --help) usage 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done
[ -n "$COMMAND" ] || usage 1
[ "$COMMAND" = "sync-issue" ] && WRITE_ISSUE=true

# ---------------------------------------------------------------------------
# Classification (pure)
# ---------------------------------------------------------------------------
#
# `compare` reports HEAD relative to BASE, so `TARGET...PINNED` yields:
#   identical  the pin is exactly the target
#   behind     the pin is an ancestor of the target - ordinary lag
#   ahead      the pin contains commits the target does not
#   diverged   both, which for a pin means it sits on an abandoned line
#
# `ahead` and `diverged` are the worse defect and are reported separately: they
# mean someone pinned a PR head or a force-pushed commit, so the consumer runs
# code that was never reviewed onto main and may vanish when the branch is
# deleted. That is not lag and must not be filed as lag.
#
# classify_reference <ref> <relation> <pinned_blob> <target_blob> <workflow>
#
# Pure: no network. Sets VERDICT, CONTENT and DETAIL. Kept separate from the
# fetching loop, and reachable through the `classify` subcommand, so the whole
# truth table can be exercised without the org's live state - including the
# `broken` and `unpinned-ref` rows, which have no live instance to observe and
# would otherwise be asserted only by reading the source.
# One owner for "is this a pin". The fetching loop needs the same answer to
# decide whether comparing is even meaningful, and two copies of the rule could
# disagree - the loop would compare a ref the classifier then called unpinned.
is_full_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

classify_reference() {
  local ref="$1" relation="$2" pinned_blob="$3" target_blob="$4" workflow="$5"
  VERDICT=""
  CONTENT=""
  DETAIL=""

  if ! is_full_sha "$ref"; then
    # Owned by harn's lint-actions-source. Censused, never actioned here.
    VERDICT="unpinned-ref"
    CONTENT="n/a"
    DETAIL="ref is not a 40-character SHA"
    return 0
  fi

  case "$relation" in
    identical)
      VERDICT="current"
      CONTENT="identical"
      DETAIL="pinned to the target commit"
      ;;
    behind)
      if [ -z "$pinned_blob" ]; then
        VERDICT="broken"
        CONTENT="missing"
        DETAIL="${workflow} does not exist at the pinned commit"
      elif [ "$pinned_blob" = "$target_blob" ]; then
        VERDICT="behind-equivalent"
        CONTENT="identical"
        DETAIL="pin trails ${TARGET_REF} but ${workflow##*/} is byte-identical"
      else
        VERDICT="behind-stale"
        CONTENT="differs"
        DETAIL="${workflow##*/} changed after the pinned commit"
      fi
      ;;
    ahead | diverged)
      VERDICT="not-on-main"
      CONTENT="unknown"
      DETAIL="pinned commit is ${relation} relative to ${TARGET_REF}; likely a PR head"
      ;;
    *)
      VERDICT="broken"
      CONTENT="unknown"
      DETAIL="pinned commit could not be compared against ${TARGET_REF}"
      ;;
  esac
}

# Overlay the caller/callee output contract on the pin-freshness verdict.
# classify_output_contract <base-verdict> <base-detail> <job> <workflow> <ref>
#                          <required-json> <pinned-json> <target-json>
classify_output_contract() {
  local base_verdict="$1" base_detail="$2" job="$3" workflow="$4" ref="$5"
  local required="$6" pinned="$7" target="$8"
  local missing_pinned missing_target missing_text

  VERDICT="$base_verdict"
  DETAIL="$base_detail"
  MISSING_OUTPUTS="[]"
  missing_pinned="$(jq -cn --argjson required "$required" --argjson declared "$pinned" \
    '$required - $declared | unique | sort')"
  missing_target="$(jq -cn --argjson required "$required" --argjson declared "$target" \
    '$required - $declared | unique | sort')"

  if [ "$(jq 'length' <<< "$missing_pinned")" -gt 0 ]; then
    VERDICT="missing-output"
    MISSING_OUTPUTS="$missing_pinned"
    missing_text="$(jq -r 'join(", ")' <<< "$missing_pinned")"
    DETAIL="needs.${job}.outputs reads undeclared output(s) ${missing_text} at ${ref:0:12}"
    if [ "$(jq 'length' <<< "$missing_target")" -eq 0 ]; then
      DETAIL="${DETAIL}; target ${TARGET_SHA:0:12} declares them"
    else
      DETAIL="${DETAIL}; target ${TARGET_SHA:0:12} also omits them"
    fi
  elif [ "$(jq 'length' <<< "$missing_target")" -gt 0 ]; then
    VERDICT="target-missing-output"
    MISSING_OUTPUTS="$missing_target"
    missing_text="$(jq -r 'join(", ")' <<< "$missing_target")"
    DETAIL="target ${TARGET_SHA:0:12} removes output(s) ${missing_text} read through needs.${job}.outputs"
  fi
}

# Actionable drift includes content drift, hard ref defects, and caller/callee
# output-contract violations. `behind-equivalent` and `unpinned-ref` are
# deliberately excluded: acting on them would train the reader to ignore this
# report, and on this org they are the majority of rows.
ACTIONABLE='["behind-stale", "not-on-main", "broken", "missing-output", "target-missing-output"]'

# Answered before any network call, so the truth table is testable offline.
if [ "$COMMAND" = "classify" ]; then
  classify_reference "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}"
  printf '%s\t%s\t%s\n' "$VERDICT" "$CONTENT" "$DETAIL"
  exit 0
fi

if [ "$COMMAND" = "classify-outputs" ]; then
  command -v jq > /dev/null 2>&1 || die "jq is required"
  TARGET_SHA="${8:-}"
  classify_output_contract \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" \
    "${6:-[]}" "${7:-[]}" "${9:-[]}"
  printf '%s\t%s\t%s\n' "$VERDICT" "$MISSING_OUTPUTS" "$DETAIL"
  exit 0
fi

# Staleness states that keep the report open. `unknown` is here on purpose: a
# pin that could not be measured must never read as clean. `pending` (newer
# commits still inside the grace period) is listed but not flagged.
STALE_FLAGGED='["stale", "unknown"]'

# stale_pin_count <classified-json> -> distinct (repo, workflow, ref) pins flagged
stale_pin_count() {
  jq --argjson f "$STALE_FLAGGED" '
    [.[] | select(.staleness != null and (.staleness.state as $s | $f | index($s)))
     | [.repo, .workflow, .ref]] | unique | length' <<< "$1"
}

# render_staleness <classified-json>: per caller repo, per pin, the measured
# newer commits. Pure, so the `render-staleness` seam tests it offline. Current
# pins are omitted: they have nothing to report.
render_staleness() {
  local listed
  printf '## Stale pins\n\n'
  printf 'Commits to `%s` since each pin that touched the pinned workflow or a path\n' "$TARGET_REF"
  printf 'it checks out or runs at its own ref. **stale**: the oldest is past the grace\n'
  printf 'period. pending: inside it, not flagged. **unknown**: not measurable, never clean.\n\n'
  listed="$(jq -r --argjson f "$STALE_FLAGGED" '
    def days: . / 86400 * 10 | floor / 10;
    [.[] | select(.staleness != null and .staleness.state != "current")]
    | group_by(.repo)[]
    | "### `\(.[0].repo)`\n",
      (group_by(.workflow + "@" + .ref)[]
       | length as $sites
       | .[0] as $r
       | ($r.staleness) as $s
       | ($r.workflow | split("/") | last) as $name
       | (if ($f | index($s.state)) then "**\($s.state)**" else $s.state end) as $state
       | (if $sites > 1 then " (\($sites) call sites)" else "" end) as $where
       | if $s.state == "unknown" then
           "- `\($name)` pinned `\($r.ref[0:8])`\($where): \($state), \($s.detail)"
         else
           "- `\($name)` pinned `\($r.ref[0:8])`\($where): \($state), \($s.count) newer commit(s), oldest \($s.oldest_age_seconds | days)d old",
           ($s.commits[0:10][] | "  - `\(.sha[0:8])` \(.subject)"),
           (if ($s.commits | length) > 10 then "  - and \(($s.commits | length) - 10) more" else empty end)
         end),
      ""
  ' <<< "$1")"
  if [ -n "$listed" ]; then
    printf '%s\n' "$listed"
  else
    printf 'No pin trails a commit that touched what it executes.\n\n'
  fi
}

if [ "$COMMAND" = "render-staleness" ]; then
  command -v jq > /dev/null 2>&1 || die "jq is required"
  rows_in="$(cat)"
  TARGET_REF="${1:-$TARGET_REF}"
  render_staleness "$rows_in"
  printf -- '- Stale pins: %s\n' "$(stale_pin_count "$rows_in")"
  exit 0
fi

command -v gh > /dev/null 2>&1 || die "gh is required"
command -v jq > /dev/null 2>&1 || die "jq is required"
command -v ruby > /dev/null 2>&1 || die "ruby is required"
[ -f "$CONTRACT_HELPER" ] || die "missing structural contract helper: $CONTRACT_HELPER"

# ---------------------------------------------------------------------------
# Resolve what "current" means
# ---------------------------------------------------------------------------

TARGET_SHA="$(gh api "repos/${ORG}/${POLICY_REPO}/commits/${TARGET_REF}" --jq '.sha')" ||
  die "could not resolve ${ORG}/${POLICY_REPO}@${TARGET_REF}"
[ -n "$TARGET_SHA" ] || die "empty target sha for ${TARGET_REF}"
note "target: ${ORG}/${POLICY_REPO}@${TARGET_REF} = ${TARGET_SHA}"

# Staleness is read from local history. A shallow clone, or one that does not
# contain the target, would make every pin unmeasurable; fail here rather than
# file a report where every row is UNKNOWN for a reason the reader cannot see.
command -v git > /dev/null 2>&1 || die "git is required"
[ "$(git -C "$POLICY_GIT_DIR" rev-parse --is-shallow-repository 2> /dev/null)" = "false" ] ||
  die "${POLICY_GIT_DIR} is not a full-history clone; check out with fetch-depth: 0 or set PIN_DRIFT_GIT_DIR"
git -C "$POLICY_GIT_DIR" cat-file -e "${TARGET_SHA}^{commit}" 2> /dev/null ||
  die "${POLICY_GIT_DIR} does not contain ${TARGET_SHA}; fetch ${TARGET_REF} first"

# ---------------------------------------------------------------------------
# Enumerate consumers by CONTENT, never from a hardcoded repo list
# ---------------------------------------------------------------------------
#
# A new consumer repo must not be invisible to this check, so the repo set comes
# from the org listing rather than a list someone has to remember to edit.
#
# Two enumeration traps this avoids, both hit in this org already:
#
#   * `search/code` drops results PER QUERY. Counting burin-code's callers of
#     runner-availability.yml returned 7 via search/code and 8 via `git grep`;
#     the missed file was returned by a DIFFERENT query in the same session. An
#     index that silently omits one consumer produces a confidently wrong
#     "every consumer is level" verdict, which is this script's whole claim.
#   * Unpaginated list reads. burin-labs reached 1015 runner registrations, 1002
#     of them vendor ephemerals, which pushed real entries off page 1 of an
#     unpaginated read. Every list here is `--paginate`d for that reason.
#
# So enumeration walks the git tree of each repo's default branch and reads the
# workflow blobs directly. It is more API calls than a code search and it is
# exhaustive, which is the correct trade for a claim of completeness.

repos_json="$(gh api --paginate "/orgs/${ORG}/repos?per_page=100&type=all" \
  --jq '.[] | select(.archived == false) | {name, default_branch}' | jq -s '.')" ||
  die "could not list ${ORG} repositories"
repo_count="$(jq 'length' <<< "$repos_json")"
note "scanning ${repo_count} non-archived repositories"

rows="[]"
scanned_workflows=0

while IFS=$'\t' read -r repo default_branch; do
  [ -n "$repo" ] || continue

  # One tree read per repo yields every path at once. Filtering client-side
  # keeps this O(1) API calls per repo for discovery, versus one directory
  # listing per nested path.
  tree="$(gh api "repos/${ORG}/${repo}/git/trees/${default_branch}?recursive=1" \
    --jq '[.tree[] | select(.type == "blob") | .path]' 2> /dev/null)" || tree=""
  [ -n "$tree" ] || continue

  workflow_paths="$(jq -r '.[] | select(test("^\\.github/workflows/[^/]+\\.ya?ml$"))' <<< "$tree" 2> /dev/null || true)"
  [ -n "$workflow_paths" ] || continue

  while IFS= read -r wf_path; do
    [ -n "$wf_path" ] || continue
    scanned_workflows=$((scanned_workflows + 1))

    body="$(gh api "repos/${ORG}/${repo}/contents/${wf_path}?ref=${default_branch}" \
      --jq '.content' 2> /dev/null | base64 -d 2> /dev/null || true)"
    [ -n "$body" ] || continue

    # Parse the workflow as YAML so comments and arbitrary prose cannot become
    # false call sites. The same structural pass associates every reusable job
    # with the exact `needs.<job>.outputs.<name>` values its caller reads.
    references="$(ruby "$CONTRACT_HELPER" references "$ORG" "$POLICY_REPO" <<< "$body")" ||
      die "could not parse ${repo}:${wf_path}"
    rows="$(jq -c \
      --arg repo "$repo" \
      --arg path "$wf_path" \
      --argjson references "$references" \
      '. + ($references | map(. + {repo: $repo, path: $path}))' \
      <<< "$rows")"
  done <<< "$workflow_paths"
done <<< "$(jq -r '.[] | [.name, .default_branch] | @tsv' <<< "$repos_json")"

note "scanned ${scanned_workflows} workflow files; found $(jq 'length' <<< "$rows") reference(s)"

# ---------------------------------------------------------------------------
# Classify each reference
# ---------------------------------------------------------------------------
#
# `compare` reports HEAD relative to BASE, so `TARGET...PINNED` yields:
#   identical  the pin is exactly the target
#   behind     the pin is an ancestor of the target - ordinary lag
#   ahead      the pin contains commits the target does not
#   diverged   both, which for a pin means it sits on an abandoned line
#
# `ahead` and `diverged` are the worse defect and are reported separately: they
# mean someone pinned a PR head or a force-pushed commit, so the consumer runs
# code that was never reviewed onto main and may vanish when the branch is
# deleted. That is not lag and must not be filed as lag.

blob_at() {
  # blob_at <ref> <path> -> blob sha, or empty when the path is absent there
  gh api "repos/${ORG}/${POLICY_REPO}/contents/$2?ref=$1" --jq '.sha' 2> /dev/null || true
}

# Memoized as newline-delimited "key<TAB>value" records rather than associative
# arrays: macOS ships bash 3.2, where `declare -A` is a syntax error, and this
# script must stay runnable by hand on a maintainer's Mac and not only on CI.
#
# These set a global instead of printing, because a function whose result is read
# through `$(...)` runs in a subshell and its cache write is discarded there -
# the lookup would silently never hit and every row would re-request.
MEMO=""
MEMO_RESULT=""

memo_lookup() {
  MEMO_RESULT="$(awk -F'\t' -v k="$1" '$1 == k { print $2; found = 1; exit } END { exit !found }' <<< "$MEMO")"
}

# An absent path is a real answer, so it is cached behind a sentinel rather than
# as the empty string, which would be indistinguishable from a cache miss.
ABSENT="__absent__"

cached_compare() {
  local ref="$1"
  if memo_lookup "compare:${ref}"; then return 0; fi
  MEMO_RESULT="$(gh api "repos/${ORG}/${POLICY_REPO}/compare/${TARGET_SHA}...${ref}" \
    --jq '.status' 2> /dev/null || echo "unknown")"
  [ -n "$MEMO_RESULT" ] || MEMO_RESULT="unknown"
  MEMO="${MEMO}compare:${ref}	${MEMO_RESULT}
"
}

cached_blob() {
  local ref="$1" path="$2"
  if memo_lookup "blob:${ref}:${path}"; then
    [ "$MEMO_RESULT" = "$ABSENT" ] && MEMO_RESULT=""
    return 0
  fi
  MEMO_RESULT="$(blob_at "$ref" "$path")"
  MEMO="${MEMO}blob:${ref}:${path}	${MEMO_RESULT:-$ABSENT}
"
}

cached_declared_outputs() {
  local ref="$1" path="$2" encoded=""
  if memo_lookup "outputs:${ref}:${path}"; then
    [ "$MEMO_RESULT" = "$ABSENT" ] && MEMO_RESULT=""
    return 0
  fi
  encoded="$(gh api "repos/${ORG}/${POLICY_REPO}/contents/${path}?ref=${ref}" \
    --jq '.content' 2> /dev/null || true)"
  if [ -z "$encoded" ]; then
    MEMO_RESULT=""
    MEMO="${MEMO}outputs:${ref}:${path}"$'\t'"${ABSENT}"$'\n'
    return 0
  fi
  MEMO_RESULT="$(printf '%s' "$encoded" | base64 -d | ruby "$CONTRACT_HELPER" declared-outputs | jq -c .)" ||
    die "could not decode workflow outputs for ${path}@${ref}"
  MEMO="${MEMO}outputs:${ref}:${path}"$'\t'"${MEMO_RESULT}"$'\n'
}

classified="[]"
while IFS=$'\t' read -r repo path line job workflow ref required_outputs; do
  [ -n "$repo" ] || continue

  relation="n/a"
  pinned_blob=""
  target_blob=""
  if is_full_sha "$ref"; then
    cached_compare "$ref"
    relation="$MEMO_RESULT"
    if [ "$relation" = "behind" ]; then
      cached_blob "$ref" "$workflow"
      pinned_blob="$MEMO_RESULT"
      cached_blob "$TARGET_SHA" "$workflow"
      target_blob="$MEMO_RESULT"
    fi
  fi

  classify_reference "$ref" "$relation" "$pinned_blob" "$target_blob" "$workflow"
  verdict="$VERDICT"
  content="$CONTENT"
  detail="$DETAIL"
  missing_outputs="[]"

  if is_full_sha "$ref" && [ "$(jq 'length' <<< "$required_outputs")" -gt 0 ]; then
    cached_declared_outputs "$ref" "$workflow"
    pinned_outputs="$MEMO_RESULT"
    cached_declared_outputs "$TARGET_SHA" "$workflow"
    target_outputs="$MEMO_RESULT"
    if [ -n "$pinned_outputs" ] && [ -n "$target_outputs" ]; then
      classify_output_contract \
        "$verdict" "$detail" "$job" "$workflow" "$ref" \
        "$required_outputs" "$pinned_outputs" "$target_outputs"
      verdict="$VERDICT"
      detail="$DETAIL"
      missing_outputs="$MISSING_OUTPUTS"
    fi
  fi

  # The contract verdict above compares the workflow FILE only. Staleness also
  # covers what the workflow checks out and runs at its own ref, which is where
  # the Smart Ship approval-carry fix landed while smart-ship.yml stood still.
  staleness="null"
  if is_full_sha "$ref"; then
    staleness="$(ruby "$CONTRACT_HELPER" staleness "$POLICY_GIT_DIR" "$ORG" "$POLICY_REPO" \
      "$workflow" "$ref" "$TARGET_SHA" < /dev/null)" ||
      die "could not measure staleness for ${workflow}@${ref}"
  fi

  classified="$(jq -c \
    --arg repo "$repo" --arg path "$path" --arg line "$line" \
    --arg job "$job" --arg workflow "$workflow" --arg ref "$ref" \
    --argjson required_outputs "$required_outputs" --argjson missing_outputs "$missing_outputs" \
    --arg verdict "$verdict" --arg relation "$relation" \
    --arg content "$content" --arg detail "$detail" --argjson staleness "$staleness" \
    '. + [{repo: $repo, path: $path, line: ($line | tonumber), job: $job, workflow: $workflow,
           ref: $ref, verdict: $verdict, relation: $relation, content: $content,
           required_outputs: $required_outputs, missing_outputs: $missing_outputs,
           detail: $detail, staleness: $staleness}]' <<< "$classified")"
done <<< "$(jq -r '.[] | [.repo, .path, .line, .job, .workflow, .ref, (.required_outputs | @json)] | @tsv' <<< "$rows")"

actionable_count="$(jq --argjson a "$ACTIONABLE" '[.[] | select(.verdict as $v | $a | index($v))] | length' <<< "$classified")"
stale_count="$(stale_pin_count "$classified")"

if [ "$OUTPUT_JSON" = true ]; then
  jq -n \
    --arg target_ref "$TARGET_REF" --arg target_sha "$TARGET_SHA" \
    --argjson rows "$classified" --argjson actionable "$actionable_count" \
    --argjson stale "$stale_count" --argjson scanned "$scanned_workflows" \
    '{target_ref: $target_ref, target_sha: $target_sha, scanned_workflows: $scanned,
      actionable: $actionable, stale_pins: $stale, rows: $rows}'
  exit 0
fi

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

# Every `printf` whose FORMAT begins with `-` needs the `--` terminator: bash's
# printf builtin parses a leading `-` as an option and fails with
# `printf: - : invalid option`. Markdown bullet lines hit this constantly, and
# the failure is worse than it looks - see `require_report_fields` below for how
# it shipped a truncated report while reporting success.
render_markdown() {
  printf '%s\n\n' "$ISSUE_MARKER"
  printf 'Consumers of this repository'"'"'s reusable workflows with stale code or an\n'
  printf 'output read that the pinned or target workflow does not declare.\n\n'
  printf -- '- Target: `%s` = `%s`\n' "$TARGET_REF" "$TARGET_SHA"
  printf -- '- Workflow files scanned: %s across %s non-archived repositories\n' "$scanned_workflows" "$repo_count"
  printf -- '- Actionable: **%s**\n' "$actionable_count"
  printf -- '- Stale pins: **%s**\n\n' "$stale_count"

  if [ "$actionable_count" -gt 0 ]; then
    printf '## Actionable\n\n'
    printf 'For stale pins, update to `%s`. For output-contract rows, follow the\n' "$TARGET_SHA"
    printf 'row detail: update only when the target declares the required output; repair\n'
    printf 'the target workflow first when it does not. Enumerate a repo'"'"'s call sites with\n'
    printf '`git grep -n '"'"'%s/%s/.github/workflows'"'"' origin/main -- .github/`\n' "$ORG" "$POLICY_REPO"
    printf 'rather than the code-search API, which drops results per query.\n\n'
    printf '| Consumer | Workflow | Pinned | State | Why |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    jq -r --argjson a "$ACTIONABLE" '
      [.[] | select(.verdict as $v | $a | index($v))]
      | sort_by(.repo, .path, .line)[]
      | "| `\(.repo)` `\(.path)`:\(.line) | `\(.workflow | split("/") | last)` | `\(.ref[0:12])` | **\(.verdict)** | \(.detail) |"
    ' <<< "$classified"
    printf '\n'
  else
    printf '## No drift\n\n'
    printf 'Every pinned consumer resolves to current or byte-equivalent workflow content,\n'
    printf 'and every output read is declared at both the pin and `%s`.\n\n' "$TARGET_REF"
  fi

  local informational
  informational="$(jq -r --argjson a "$ACTIONABLE" '
    [.[] | select(.verdict as $v | $a | index($v) | not)]
    | sort_by(.repo, .path, .line)[]
    | "| `\(.repo)` `\(.path)`:\(.line) | `\(.workflow | split("/") | last)` | `\(.ref[0:12])` | \(.verdict) | \(.detail) |"
  ' <<< "$classified")"
  if [ -n "$informational" ]; then
    printf '## Informational\n\n'
    printf 'No action required. `behind-equivalent` pins trail `%s` but call\n' "$TARGET_REF"
    printf 'byte-identical content. `unpinned-ref` rows are owned by harn'"'"'s\n'
    printf '`make lint-actions-source`, not by this check.\n\n'
    printf '| Consumer | Workflow | Pinned | State | Why |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    printf '%s\n\n' "$informational"
  fi

  render_staleness "$classified"

  printf -- '---\n\n'
  printf 'Filed by `scripts/reusable-pin-drift.sh`. Static consumer guards check pin\n'
  printf 'shape; this network-owning audit checks content freshness and exact-SHA output contracts.\n'
}

if [ "$WRITE_ISSUE" = false ]; then
  render_markdown
  exit 0
fi

# ---------------------------------------------------------------------------
# Idempotent issue sync
# ---------------------------------------------------------------------------
#
# One issue, reused. A failing scheduled job is invisible unless someone is
# already watching Actions, and one issue per drifted pin would file eight the
# first time this repo's detector changes - correlated by construction, since a
# single commit here drifts every consumer at once. So: exactly one open issue,
# body rewritten in place, closed when drift clears.
#
# Re-findable by marker rather than by label (no label needs to pre-exist) and
# by listing rather than by search (the search index lags, and a missed hit here
# would file a duplicate).

existing="$(gh issue list --repo "${ORG}/${POLICY_REPO}" --state open \
  --limit 100 --json number,title,body \
  --jq "[.[] | select(.body | contains(\"${ISSUE_MARKER}\")) | .number] | first // empty")"

# The rendered body IS the product, so verify it before publishing rather than
# trusting the renderer's exit status. `body="$(render_markdown)"` did not
# propagate a failing `printf` under `set -e` (errexit is not reliably inherited
# into a command substitution used in an assignment), so on 2026-07-30 three
# failed `printf` calls silently dropped the target SHA, the census size and the
# actionable count, and the issue was filed and reported as a success. The
# `report` subcommand caught the same failure only because it redirects, where
# the exit status does propagate. This check is deliberately independent of exit
# codes: a body that lost its headline numbers must never be published again, no
# matter which mechanism drops them.
require_report_fields() {
  local rendered="$1" missing=""
  local field
  for field in '- Target:' '- Workflow files scanned:' '- Actionable:' '- Stale pins:'; do
    case "$rendered" in
      *"$field"*) : ;;
      *) missing="${missing}${missing:+, }${field}" ;;
    esac
  done
  [ -z "$missing" ] || die "rendered report is missing required field(s): ${missing}"
}

body="$(render_markdown)"
require_report_fields "$body"

# One issue carries both findings, and it closes only when both are clean.
if [ "$actionable_count" -gt 0 ] || [ "$stale_count" -gt 0 ]; then
  if [ -n "$existing" ]; then
    gh issue edit "$existing" --repo "${ORG}/${POLICY_REPO}" \
      --title "$ISSUE_TITLE" --body "$body" > /dev/null
    echo "updated ${ORG}/${POLICY_REPO}#${existing} (${actionable_count} actionable, ${stale_count} stale pins)"
  else
    url="$(gh issue create --repo "${ORG}/${POLICY_REPO}" \
      --title "$ISSUE_TITLE" --body "$body")"
    echo "filed ${url} (${actionable_count} actionable, ${stale_count} stale pins)"
  fi
else
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "${ORG}/${POLICY_REPO}" \
      --body "Drift cleared: every pinned consumer now resolves to the same workflow content as \`${TARGET_REF}\` (\`${TARGET_SHA}\`), and no pin trails a past-grace commit to a path it executes. Closing." > /dev/null
    gh issue close "$existing" --repo "${ORG}/${POLICY_REPO}" > /dev/null
    echo "closed ${ORG}/${POLICY_REPO}#${existing} (no drift)"
  else
    echo "no drift, no open report; nothing to do"
  fi
fi

#!/usr/bin/env bash
#
# reusable-pin-drift.sh - report stale reusable workflow pins and callers that
# read outputs their exact pin does not declare.
#
#   reusable-pin-drift.sh report              human-readable table
#   reusable-pin-drift.sh report --json       machine-readable rows
#   reusable-pin-drift.sh sync-issue          file/update/close the drift issue
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

  classified="$(jq -c \
    --arg repo "$repo" --arg path "$path" --arg line "$line" \
    --arg job "$job" --arg workflow "$workflow" --arg ref "$ref" \
    --argjson required_outputs "$required_outputs" --argjson missing_outputs "$missing_outputs" \
    --arg verdict "$verdict" --arg relation "$relation" \
    --arg content "$content" --arg detail "$detail" \
    '. + [{repo: $repo, path: $path, line: ($line | tonumber), job: $job, workflow: $workflow,
           ref: $ref, verdict: $verdict, relation: $relation, content: $content,
           required_outputs: $required_outputs, missing_outputs: $missing_outputs,
           detail: $detail}]' <<< "$classified")"
done <<< "$(jq -r '.[] | [.repo, .path, .line, .job, .workflow, .ref, (.required_outputs | @json)] | @tsv' <<< "$rows")"

actionable_count="$(jq --argjson a "$ACTIONABLE" '[.[] | select(.verdict as $v | $a | index($v))] | length' <<< "$classified")"

if [ "$OUTPUT_JSON" = true ]; then
  jq -n \
    --arg target_ref "$TARGET_REF" --arg target_sha "$TARGET_SHA" \
    --argjson rows "$classified" --argjson actionable "$actionable_count" \
    --argjson scanned "$scanned_workflows" \
    '{target_ref: $target_ref, target_sha: $target_sha, scanned_workflows: $scanned,
      actionable: $actionable, rows: $rows}'
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
  printf -- '- Actionable: **%s**\n\n' "$actionable_count"

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
  for field in '- Target:' '- Workflow files scanned:' '- Actionable:'; do
    case "$rendered" in
      *"$field"*) : ;;
      *) missing="${missing}${missing:+, }${field}" ;;
    esac
  done
  [ -z "$missing" ] || die "rendered report is missing required field(s): ${missing}"
}

body="$(render_markdown)"
require_report_fields "$body"

if [ "$actionable_count" -gt 0 ]; then
  if [ -n "$existing" ]; then
    gh issue edit "$existing" --repo "${ORG}/${POLICY_REPO}" \
      --title "$ISSUE_TITLE" --body "$body" > /dev/null
    echo "updated ${ORG}/${POLICY_REPO}#${existing} (${actionable_count} actionable)"
  else
    url="$(gh issue create --repo "${ORG}/${POLICY_REPO}" \
      --title "$ISSUE_TITLE" --body "$body")"
    echo "filed ${url} (${actionable_count} actionable)"
  fi
else
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "${ORG}/${POLICY_REPO}" \
      --body "Drift cleared: every pinned consumer now resolves to the same workflow content as \`${TARGET_REF}\` (\`${TARGET_SHA}\`). Closing." > /dev/null
    gh issue close "$existing" --repo "${ORG}/${POLICY_REPO}" > /dev/null
    echo "closed ${ORG}/${POLICY_REPO}#${existing} (no drift)"
  else
    echo "no drift, no open report; nothing to do"
  fi
fi

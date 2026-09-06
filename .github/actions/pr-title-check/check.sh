#!/usr/bin/env bash
# Validates PR_NUMBER's title against `[Area] Sentence case` and confirms the
# description carries real prose rather than the untouched template. Reads only
# the PR's own title and body via `gh pr view`; makes no assumptions about
# repository state, so it cannot pass on an unrelated green build.
set -euo pipefail

: "${REPO:?}"
: "${AREAS:?}"

# A pull request number is the only thing this check can act on. On
# `merge_group` and `push` the event carries none, and a hard failure there
# would deadlock a merge queue on a check that was never meant to run. Skip
# loudly instead. Gate the step on `github.event_name == 'pull_request'` as
# well; this is the backstop, not the gate.
if [[ -z "${PR_NUMBER:-}" ]]; then
  echo "No pull request number in this event, skipping the title and description check."
  exit 0
fi

pr_json="$(gh pr view "$PR_NUMBER" -R "$REPO" --json title,body,isDraft)"
title="$(jq -r '.title' <<<"$pr_json")"
body="$(jq -r '.body' <<<"$pr_json")"
is_draft="$(jq -r '.isDraft' <<<"$pr_json")"

if [[ "$is_draft" == "true" ]] && [[ "$title" == WIP\ \(recovered\):* ]]; then
  echo "Draft WIP-recovered PR, skipping title/body shape check."
  exit 0
fi

# Two title shapes are load-bearing for automation outside this check's
# control and must never be blocked by it:
#   - `Release vX.Y.Z` is matched verbatim by release-tagging workflows
#     (for example harn's publish-release.yml) before they tag and publish.
#   - Dependabot always opens PRs with a conventional-commit title
#     (`chore(deps...): ...` / `build(deps...): ...`, case-insensitive on the
#     leading word), and does not read repository-specific title rules.
if [[ "$title" =~ ^Release\ v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || [[ "$title" =~ ^[Cc]hore\(deps(-dev)?[^\)]*\): ]] \
  || [[ "$title" =~ ^[Bb]uild\(deps(-dev)?[^\)]*\): ]]; then
  echo "Exempt automation title, skipping title/body shape check: ${title}"
  exit 0
fi

# Build an alternation from the pipe-separated area list, escaping regex
# metacharacters in each area name.
IFS='|' read -ra area_list <<<"$AREAS"
escaped=()
for area in "${area_list[@]}"; do
  escaped+=("$(printf '%s' "$area" | sed -e 's/[].[^$*+?(){}|\\]/\\&/g')")
done
alternation="$(IFS='|'; echo "${escaped[*]}")"

# A repository's coarse title vocabulary does not necessarily use the words a
# contributor knows from another Burin repository. Keep those semantic hints
# beside that repository's accepted list instead of guessing from spelling.
suggestion_list=()
if [[ -n "${AREA_SUGGESTIONS:-}" ]]; then
  IFS='|' read -ra suggestion_list <<<"$AREA_SUGGESTIONS"
  for mapping in "${suggestion_list[@]}"; do
    rejected="${mapping%%=*}"
    accepted="${mapping#*=}"
    if [[ "$mapping" != *=* || -z "$rejected" || -z "$accepted" ]]; then
      echo "::error::Invalid area suggestion '${mapping}'; expected Rejected=Accepted where Accepted is in ${AREAS}"
      exit 1
    fi
    case "|${AREAS}|" in
      *"|${accepted}|"*) ;;
      *)
        echo "::error::Invalid area suggestion '${mapping}'; expected Rejected=Accepted where Accepted is in ${AREAS}"
        exit 1
        ;;
    esac
  done
fi

title_pattern="^\[(${alternation})\] [A-Z0-9].*[^.]$"
if [[ ! "$title" =~ $title_pattern ]]; then
  echo "::error::PR title must match '[Area] Sentence case summary', where Area is one of: ${AREAS}"
  echo "::error::Got: ${title}"
  if [[ "$title" =~ ^\[([^]]+)\] ]]; then
    rejected_area="${BASH_REMATCH[1]}"
    for mapping in "${suggestion_list[@]}"; do
      if [[ "${mapping%%=*}" == "$rejected_area" ]]; then
        echo "::error::For [${rejected_area}], use [${mapping#*=}]."
        break
      fi
    done
  fi
  echo "See .github/pull_request_template.md and AGENTS.md for the convention."
  exit 1
fi

# Count only prose the author wrote. Everything the template, the tooling, or
# GitHub itself contributes is stripped first, because a body made entirely of
# scaffolding is an unfilled template and must not read as a filled one:
#   - HTML comments (the template's guidance)
#   - Markdown headings (the template's section headers)
#   - list and checklist items (repository-specific checklists)
#   - fenced code blocks and quoted logs
#   - issue reference lines, the generated-by footer, and bot footers
prose="$(
  printf '%s\n' "$body" \
    | sed -e '/<!--/,/-->/d' \
    | sed -e '/^[[:space:]]*```/,/^[[:space:]]*```/d' \
    | grep -v -E '^[[:space:]]*#' \
    | grep -v -E '^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]' \
    | grep -v -E '^[[:space:]]*>' \
    | grep -v -E '^[[:space:]]*(Closes|Fixes|Resolves|Single-ask|Part of|Refs)[[:space:]:]+#[0-9]+' \
    | grep -v -E '(Generated with \[Claude Code\]|claude\.ai/code/session|Co-Authored-By:|codesmith)' \
    | grep -v -E '^[[:space:]]*(---|\|)' \
    | sed -e 's/<[^>]*>//g'
)"

word_count="$(printf '%s' "$prose" | tr -s '[:space:]' '\n' | grep -c '[[:alnum:]]' || true)"
readonly MIN_WORDS=20
if (( word_count < MIN_WORDS )); then
  echo "::error::PR description has ${word_count} words of author prose; at least ${MIN_WORDS} are required."
  echo "::error::Headings, checklists, template comments, issue links, and footers do not count."
  echo "::error::Write three to five sentences: what changed, why, the one risk, and how you verified it."
  exit 1
fi

echo "PR title and description shape OK (${word_count} words of description prose)."

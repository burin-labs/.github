#!/usr/bin/env bash
# Validates PR_NUMBER's title against `[Area] Sentence case` and confirms the
# description template sections were actually filled in. Reads only the PR's
# own title/body via `gh pr view`; makes no repository-state assumptions.
set -euo pipefail

: "${REPO:?}"
: "${PR_NUMBER:?}"
: "${AREAS:?}"

pr_json="$(gh pr view "$PR_NUMBER" -R "$REPO" --json title,body,isDraft)"
title="$(jq -r '.title' <<<"$pr_json")"
body="$(jq -r '.body' <<<"$pr_json")"
is_draft="$(jq -r '.isDraft' <<<"$pr_json")"

if [[ "$is_draft" == "true" ]] && [[ "$title" == WIP\ \(recovered\):* ]]; then
  echo "Draft WIP-recovered PR, skipping title/body shape check."
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

title_pattern="^\[(${alternation})\] [A-Z0-9].*[^.]$"
if [[ ! "$title" =~ $title_pattern ]]; then
  echo "::error::PR title must match '[Area] Sentence case description', where Area is one of: ${AREAS}"
  echo "::error::Got: ${title}"
  echo "See .github/pull_request_template.md and AGENTS.md for the convention."
  exit 1
fi

if [[ -z "${body// /}" ]]; then
  echo "::error::PR description is empty. Fill in the pull request template."
  exit 1
fi

# The template ships HTML-comment placeholders; a body that still contains
# only comments and no prose was never actually filled in.
prose="$(sed -e '/<!--/,/-->/d' <<<"$body" | tr -d '[:space:]')"
if [[ -z "$prose" ]]; then
  echo "::error::PR description still has the template placeholders with no content. Describe what changed, why, the risk, and how it was verified."
  exit 1
fi

echo "PR title and description shape OK."

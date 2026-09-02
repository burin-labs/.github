# Contributing

This repository holds Burin Labs' shared GitHub Actions, org-wide defaults,
and cross-repository skills. Every other Burin Labs repository depends on it,
so a change here can affect CI everywhere at once.

## Before you open a pull request

1. Pin any reference to an action or reusable workflow in this repository to
   a full commit SHA in your consuming repository, never a branch or tag. The
   actions here are meant to be immutable once referenced.
2. Add or update the Ruby or shell test next to the script you changed
   (`*_test.rb` or `*_test.sh` beside the script). Run it before you push.
3. If you change a reusable workflow's inputs or outputs, update every
   caller you can find with `grep -rl "uses: burin-labs/.github"` across the
   repositories you have access to, in the same pull request or a linked
   follow-up.

## Pull request title and description

Title it `[Area] Sentence case description`, for example `[CI] Fix flaky
release runner probe`. Use one of: `CI`, `Actions`, `Labels`, `Templates`,
`Docs`, `Skills`. Keep the description to 3-5 sentences: what changed, why,
the one risk, and how you verified it. See `.github/pull_request_template.md`
for a worked example.

## Documentation

Any Markdown page you add or edit follows the
[house-style skill](skills/house-style/SKILL.md): one Diátaxis mode per page,
second person, sentence-case headings, no em dashes, and a stated verification
for every claim.

## Questions

Open an issue in this repository, or ask in the repository's usual Burin Labs
coordination channel if you already have access to it.

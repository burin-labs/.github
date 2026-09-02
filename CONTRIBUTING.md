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

## Title the pull request

Use `[Area] Sentence case summary`, for example
`[CI] Fix the flaky release runner probe`. The area is one of `CI`, `Actions`,
`Labels`, `Templates`, `Docs`, or `Skills`. Do not end the title with a
period. This repository checks its own titles against that list in CI, so a
title outside it fails the build.

## Write the description

Write three to five sentences. Say what changed, why, the one risk, and how
you verified it. Leave out anything the pull request page already shows: the
Files tab lists the files and the Checks tab lists the test runs.

Here is a description that does the job:

> Fixes the release runner health check reporting `unknown` for any runner
> that finished a job in the last minute, because the liveness probe read a
> stale cache entry instead of asking the runner again. Fleet dashboards
> flapped between up and down during every deploy window. The risk is that a
> runner which is genuinely down now reads as live for one cache interval,
> thirty seconds, before the next probe corrects it. Replaying last week's
> flap incidents against the fixed probe left none of them.

Four sentences. A reader learns the symptom, the cause, what it costs them if
the fix is wrong, and what evidence stands behind it. No file list, no test
commands, no checklist.

Link the issue on its own line. Use `Closes #123 items: 1, 2` when the issue
is a numbered list of asks and this pull request closes some of them, or
`Single-ask: #123` when it is not.

## Documentation

Any Markdown page you add or edit follows the
[house-style skill](skills/house-style/SKILL.md): one Diátaxis mode per page,
second person, sentence-case headings, no em dashes, and a stated verification
for every claim.

## Questions

Open an issue in this repository, or ask in the repository's usual Burin Labs
coordination channel if you already have access to it.

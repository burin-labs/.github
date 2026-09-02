# Why the pull request and label conventions look like this

This page explains the choices behind the organization's pull request title
format, description template, and label taxonomy. It is the owner of those
decisions. If you want the rules themselves, read the README section on the
pull request convention and `CONTRIBUTING.md`. If you want to know why a
rule is not something else, read on.

Written 2026-09-02, after comparing the conventions against what large public
projects do today.

## Bracketed areas, not Conventional Commits

Pull request titles are `[Area] Sentence case summary`. The obvious
alternative was [Conventional Commits](https://www.conventionalcommits.org/),
which is what Deno and Angular enforce.

We kept brackets for two reasons. First, the format is mainstream at a much
larger scale than ours: React ships titles like
`[DevTools] Fix reconciliation of content with fallback Fiber`, and LLVM
ships `[orc-rt] Remove redundant qualifications`. Kubernetes, Rust, and VS
Code enforce no title rule at all. There is no convergence in the field to
move toward.

Second, the only thing Conventional Commits would buy us is automatic
changelog generation through
[release-please](https://github.com/googleapis/release-please) or
[semantic-release](https://semantic-release.gitbook.io/), and we already
generate changelogs from `changelog.d/` fragments that the author writes.
Fragments are the same model as
[changesets](https://github.com/changesets/changesets), and they do not read
commit subjects. We forfeit nothing we use.

A repository that publishes a versioned package to npm or crates.io and wants
semver derived from history is free to adopt Conventional Commits locally.
The shared check exempts Dependabot's conventional titles already.

## The template holds no prose

`.github/pull_request_template.md` is one HTML comment and nothing else. A new
pull request therefore opens with an empty body.

This is not a style preference. GitHub prefills the template into the body
verbatim, so any example sentence in the template becomes the author's
description the moment somebody opens a pull request without editing it. The
first version of this template carried a worked example about a release runner
probe. Every repository that inherited it would have started shipping pull
requests claiming to fix a runner probe. Rust, Deno, and VS Code all ship
templates that are entirely comments, for the same reason.

The worked example lives in `CONTRIBUTING.md` instead, and the template points
at it.

## The description check counts author prose only

An earlier version of `pr-title-check` tested the body by stripping HTML
comments and failing if nothing was left. That test passed on any template
that prefilled a heading, which is most of them, and it passed on the
fabricated example above. It could not tell a filled template from an empty
one.

The check now strips comments, headings, list and checklist items, block
quotes, fenced code, issue reference lines, and generated footers, then
requires at least twenty words. `check_test.sh` includes the unfilled template
as a case that must fail.

## The check skips events with no pull request number

`merge_group` and `push` events carry no pull request. A check that read a
missing number and failed closed would block a merge queue on a question it
cannot ask. The action skips and says so, and the documented wiring also gates
the step on the `pull_request` event. Both layers exist because the gate is
easy to forget when copying the snippet.

## Slash-prefixed labels, and no `type/` prefix

`priority/*`, `status/*`, and `effort/*` follow the Kubernetes shape, which is
the closest thing to a standard in public projects. Rust uses single-letter
prefixes instead; nothing published favors one over the other.

There is no `type/*` prefix because GitHub's own defaults already carry that
fact. `type/bug` next to `bug` would be two labels for one thing.

Nothing syncs `.github/labels.yml`. GitHub does not inherit labels from an
organization's `.github` repository, and
[organization default labels](https://docs.github.com/en/organizations/managing-organization-settings/managing-default-labels-for-repositories-in-your-organization)
apply only to newly created repositories, not existing ones. The file is
reference. If we ever want it applied mechanically, the only maintained action
for it is `crazy-max/ghaction-github-labeler`, and its delete behavior is on by
default, which would violate the never-delete-a-label rule on first run.

## Contributor guidance lives in every repository, not only here

GitHub serves a missing `CONTRIBUTING.md` from this repository. We still write
a real one into each repository, because
[GitHub's own documentation](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)
says default files do not appear in the file browser, the git history, or
clones of the consuming repository. An agent reading a checkout would find
nothing, and absence reads as "no rules".

Composite actions and reusable workflows do not inherit either. Each
repository wires the title check itself, pinned to a commit.

## Rejected

**Conventional Commits organization-wide.** Covered above. It buys changelog
automation we do not use and costs us a format two of the largest public
codebases already validate.

**A checklist in the template.** Angular and Rails render checklists; React
hides its own inside a comment. No study measures whether they help. The
founder ask was three to five sentences, and a checklist competes with that
for the reader's attention.

**Replacing the `CLAUDE.md` symlink with an `@AGENTS.md` import.** Anthropic
documents both. The import is preferred, mainly because symlinks need
Administrator rights on Windows. Every Burin Labs repository is developed on
macOS and Linux, and changing seventy repositories to gain nothing on those
platforms is churn.

**Claiming an eighth-grade reading level as the documentation standard.** No
first-party developer style guide names a grade level. Neither
[Google](https://developers.google.com/style/tone) nor
[Microsoft](https://learn.microsoft.com/en-us/style-guide/) nor
plainlanguage.gov prescribes one. The two credible numbers, GOV.UK's reading
age of nine and WCAG 2.2 success criterion 3.1.5, address public government
writing and accessibility at level AAA, not engineering documentation. We use
the house-style rules instead: short sentences, terms defined before use, no
unexplained acronyms, and a stated verification for every claim. A readability
score is still a useful smell test on a draft. It is not the standard.

**Citing Diataxis as forbidding mixed modes in `CONTRIBUTING.md`.**
[Diataxis](https://diataxis.fr/map/) diagnoses what happens when the four
modes blur. It does not prohibit mixing, and it says nothing about
`CONTRIBUTING.md` or `README.md` at all. Keeping a contributing page mostly
how-to is good practice. It is not a rule Diataxis states.

## Proposed to the founder, not applied

These need repository or organization settings, which only the founder
changes. They are listed here so they have one home.

1. **Set the squash merge commit message to "Pull request title and
   description" on every repository.** This one matters. GitHub defaults a
   single-commit pull request to using that commit's own message, so the
   squashed subject on `main` does not come from the pull request title at
   all. Until the setting changes, the title check proves nothing about git
   history on any single-commit pull request. It still improves the pull
   request list, which is real but smaller than intended.
2. **Move `priority/*` and `effort/*` to GitHub issue fields.** Issue fields
   went generally available on 2026-07-02 with `Priority` and `Effort`
   preconfigured, and GitHub's own announcement names `priority/p0` as the
   pattern they replace. Fields are typed and organization-wide, which no
   label sync can promise across seventy repositories. Labels would stay for
   pull requests, which issue fields do not cover.
3. **Consider an organization ruleset for the title check** rather than
   per-repository wiring, if we ever want it enforced without each repository
   opting in.

---
name: house-style
short: Write Burin Labs documentation to house style.
description: Reading level, Diátaxis mode, voice, headings, claims, and generated-page rules for every page published from a Burin Labs repository.
when-to-use: Use when writing or reviewing any documentation page, README, help-center article, migration note, or changelog entry in burin-code, harn, or harn-cloud.
---

# Write to Burin Labs house style

Rules only. The reasoning, the per-repository paths, and the worked examples
live in the canonical page:
[burin-code `docs/style-guide.md`](https://github.com/burin-labs/burin-code/blob/main/docs/style-guide.md).
Read that when a rule surprises you. Do not restate it here.

For Harn-specific authoring, also load `harn-docs` (`harn skill get harn-docs
--full`). This skill is the house layer above it.

## Before you write

- Pick one Diátaxis mode for the page: tutorial, how-to, reference, or
  explanation. If you cannot pick one, split the page.
- Name the reader and the one task they arrived with.
- Read the source that owns the behavior before you describe it.

## Reading level

- Target Flesch-Kincaid grade 9 or below.
- Measure it, per page, before you ship:
  `node scripts/reading-level.mjs --max 9 <page>` in burin-code.
- One idea per sentence. Cut a clause before you shorten a word.
- A good score does not prove a readable page. Check that every product noun is
  defined before it is used.

## Voice

- Write in second person.
- Use plain product words in anything a customer reads. Keep protocol and model
  jargon in reference and diagnostics pages.
- Define a moving part the first time you use it.
- Say what breaks for a person before you explain the mechanism.
- Use they and them for a person whose pronouns you do not know.
- Use American spelling: color, behavior, center, canceled, labeled, organize,
  analyze, catalog, defense, and license as both noun and verb. Leave an
  identifier spelled the way the code spells it.

## Headings and prose

- Sentence case for every heading. Capitalize only the first word and proper
  nouns.
- One `#` per page, and it names the page.
- Never write an em dash. Use a comma, a colon, or two sentences. Leave an em
  dash alone if a person wrote it.
- Lead with the answer. Put the reasoning after it, or leave it out.
- Cut filler, hedging, restatement, forced contrast, and unfalsifiable praise.
- Cut a list of three that exists for rhythm. Keep one that has exactly three
  members.
- Replace vague claims with measurements.

## Code and commands

- Fence every block and tag its language.
- Verify every flag against the argument definitions on `origin/main` before you
  write it down. An installed binary cannot distinguish a flag that was never
  implemented from one that landed after the build.
- Never document a flag that does not exist.
- Never hand-edit a generated page. Edit its source and regenerate.
- Prefer generating a reference page from a typed source over writing one.

## Claims

- Point every product claim at the code path, test, or command that proves it.
- A screenshot proves presentation. A spinner proves animation. A test count
  proves inventory. None proves a product claim.
- Mark a hedge with an owner: `<!-- gap: repo#N -->`. A hedge with no marker is
  a claim that has been quietly abandoned.
- State the weaker claim when the evidence supports only the weaker claim.

## Links and file names

- Lowercase kebab-case file names that name the topic.
- Relative links inside a repository, full URLs across repositories.
- Link text says what the reader gets. Never "here" or "this page".
- A reference page names the artifact that owns each fact.

## Before you open the PR

- Run the reading-level check and the repository's Markdown and documentation
  checks.
- Confirm any generated page you touched was regenerated, not edited.
- Confirm the page still serves exactly one mode.

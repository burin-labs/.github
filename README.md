# .github

Burin Labs organization defaults and reusable GitHub Actions workflows.

## Selective Rust tests

`burin-labs/.github/.github/actions/rust-test-impact` is the organization-owned
adapter for branch-only Rust test impact analysis. It reads Cargo's real
workspace graph, expands directly changed packages through the transitive
reverse-dependency closure, and emits `full`, `partial`, or `empty` plus Cargo
package arguments. Merge queues, main pushes, schedules, workflow changes,
workspace manifests, lockfiles, and unresolved diffs retain the complete
workspace.

Repositories provide only the Cargo workspace path and genuinely global inputs;
they do not maintain crate dependency tables. Keep the action pinned to an exact
commit and pass exact pull-request base/head SHAs.

The planner compares those two exact trees directly. A branch behind its base
may over-select packages changed on main, but cannot omit a package changed by
the pull request; this keeps shallow checkouts fast without weakening coverage.

```yaml
- id: rust-impact
  uses: burin-labs/.github/.github/actions/rust-test-impact@<full-commit-sha>
  with:
    event-name: ${{ github.event_name }}
    base: ${{ github.event.pull_request.base.sha || github.sha }}
    head: ${{ github.event.pull_request.head.sha || github.sha }}
    workspace: crates/my-workspace
    extra-package-paths: |
      my-api=docs/openapi
- run: cargo nextest run ${{ steps.rust-impact.outputs.package-args }}
```

## Exact-tree CI proof reuse

`burin-labs/.github/.github/actions/exact-tree-ci-proof` is the organization-owned
fail-closed adapter for skipping already-proven jobs on a merge group or landing
push when the git tree matches the source pull request. Repositories name the
required jobs and a cache-contract refresh bit; they do not copy the GitHub API
helpers.

Source pull requests produce proof. Merge groups and `main` pushes consume it
only when every named job concluded `success` (not `skipped`). A
cache-contract change keeps the push writer running. Restore-only merge
groups (the default) still reuse: a rebuild there produces nothing.
Pass `merge-group-writes-cache: "true"` when the merge-group job persists a
cache, such as a sticky disk. Lookups fail closed.

```yaml
- id: rust-proof
  uses: burin-labs/.github/.github/actions/exact-tree-ci-proof@<full-commit-sha>
  with:
    workflow-file: ci.yml
    required-jobs: >-
      ["Rust TUI fast fmt, clippy & test","Rust TUI harn-linked clippy, test & build"]
    cache-refresh-required: ${{ steps.filter.outputs.rust_cache_contract }}
    merge-group-writes-cache: "true"
    event-name: ${{ github.event_name }}
    commit-sha: ${{ github.sha }}
    event-path: ${{ github.event_path }}
    github-token: ${{ github.token }}
```

## Reusable workflows

- `.github/workflows/runner-availability.yml` detects idle self-hosted Linux,
  macOS, and Windows runners and falls back to GitHub-hosted runners when the
  pool is busy, unavailable, or inaccessible from a fork/dependabot run.
- `.github/workflows/harn-package.yml` checks out a Harn package, installs its
  exact `.harn-version`, runs the Harn-owned package contract, and uploads the
  structured receipts.
- `.github/workflows/register-package-release.yml` tells the package index that
  a release shipped, so the index reconciles within minutes instead of at the
  next daily run.

## Registering package releases

A release tag and the Harn package index are two facts that have to agree, and
nothing made them agree: `harn publish` is author-invoked and wired into no
release pipeline, so `@burin/github-connector` served 0.3.0 while v0.8.3 had
shipped. See burin-labs/harn-github-connector#289.

`burin-labs/harn-packages` owns what the index should say; its reconciler
compares every indexed package against `git ls-remote` and the published
`harn.toml`, and proposes the corrections it can derive. This workflow is only
how a package repository tells the reconciler that something changed, which is
why it is one call rather than a copy of the mechanism in every package
repository:

```yaml
on:
  push:
    tags: ["v*.*.*"]

jobs:
  register:
    uses: burin-labs/.github/.github/workflows/register-package-release.yml@<full-commit-sha>
    secrets:
      RELEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_APP_CLIENT_ID }}
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

Call it as a dependent job in a release workflow where one exists, so an
unregistered release fails the release run. The token it mints can dispatch the
reconciler and read the resulting run; it cannot write the index, which stays
with the reconciler in the repository that owns it.

## Self-hosted runner health

`.github/runner-fleet.json` is the typed inventory of Burin Labs-owned runners.
The hourly `Self-hosted runner health` workflow takes two read-only GitHub
snapshots one minute apart and fails only when the same expected runner remains
missing or offline in both. Exact names exclude Blacksmith's short-lived runner
registrations. The workflow uploads a compact seven-day report and never
restarts a host; machine-local remediation remains an explicit idle-only
operation.

## Dependabot alert waivers

An open Dependabot alert must mean "a human should act". Alerts that cannot be
actioned — because upstream has published no patched version — otherwise sit
open forever, and a queue that is permanently non-empty stops being read.

The policy, in order of preference:

1. **Fix it.** If an installable patched version exists, the alert is a task,
   not noise. File it and leave the alert open.
2. **Let GitHub triage it.** GitHub's preset auto-triage rules are available on
   every repository, including private ones, and are the right tool when they
   apply. The `Dismiss low impact issues for development-scoped dependencies`
   preset only matches npm dependencies at `scope: development` carrying one of
   a curated CWE list, so it does not cover runtime-scoped findings. Custom
   auto-triage rules — which support a `snooze until a patch is available`
   action, the self-healing behaviour we want — require GitHub Code Security on
   private repositories and are UI-only; there is no REST or GraphQL API for
   them, so they cannot be provisioned from a workflow.
3. **Waive it, with evidence and an expiry.** Dismiss the alert with the closest
   accurate GitHub reason and record a waiver in the affected repository at
   `.github/dependabot-waivers.json`.

Do **not** use a `dependabot.yml` `ignore` entry for this. `ignore` suppresses
Dependabot's *pull requests*, not its *alerts* — "There is no interaction
between the settings specified in the `dependabot.yml` file and Dependabot
security alerts". It would leave the alert open and simultaneously block the
future fix, which is the same class of failure as an exact-version override.

### Why waivers need a re-check

GitHub only auto-reopens alerts that one of *its own* auto-triage rules
dismissed, and only when "the alert metadata or rule changed". An alert
dismissed by a human or through `PATCH /repos/{owner}/{repo}/dependabot/alerts/
{alert_number}` is never resurfaced — including on the day upstream finally
ships the fix. Nothing in a dismissal expires by itself.

`scripts/dependabot_waivers.rb` closes that gap. The weekly
`Dependabot waiver audit` workflow reads every repository's waiver file,
compares it against the live alert, and **reopens** the alert when the waiver
stops being true: an installable fix appeared, the severity rose, or the alert
now points at a different advisory. It fails the job when a waiver has gone
stale or has passed its `review_by` date, so the registry cannot quietly become
the new place noise accumulates.

Checking in a registry opts the repository into the policy: from then on the
audit also fails on a dismissed alert that has *no* waiver, since such a
dismissal records no reason and never expires. Repositories without a registry
are skipped entirely.

### When the fix exists but nothing can reach it

Some alerts have a published fix that this dependency graph cannot adopt,
because a third party caps the version. `tui-textarea` requires
`ratatui ^0.29`, and `ratatui 0.29` is the only thing still pulling the
vulnerable `lru`; `unsloth` requires `torch<2.12`, while the patch is `2.13`.
These are not fixable today and are not "no patch exists" either.

Such a waiver sets `observed.fix_available: true` and must add
`observed.blocked_by`, naming the blocking package, the version and requirement
read from it, the edge it `constrains`, and `override_rejected`: why forcing
the fix past the cap is not viable. That last field is required because almost
any cap *can* be overridden, and whether that is safe is a judgement no schema
can make — so it has to be made in writing and reviewed.

For these, the audit re-reads **the cap, not the patch**: any change to what the
blocking package publishes reopens the alert. It deliberately does not attempt
version-range arithmetic across three ecosystems' dialects; a changed
requirement puts a human back in the loop. Note `constrains` is often not the
vulnerable package — `tui-textarea` caps `ratatui`, and `ratatui` is what drags
in `lru`.

This is the one exception to "an available fix means it is a task, not a
waiver", and it is narrow on purpose. If the fix is reachable at all, even
awkwardly, leave the alert open and file it.

Crucially, the audit checks whether a patched version is *installable*, not
whether the advisory *claims* one. GitHub's `first_patched_version` is an
advisory claim about a product release; `GHSA-x744-4wpc-v9h2` names Docker
"29.3.1" while no such version of the `github.com/docker/docker` Go module is
published anywhere. Trusting the claim would reopen that alert on every run.

### Adding a waiver

Copy `templates/dependabot-waivers.json` into the affected repository at
`.github/dependabot-waivers.json` and check it with:

```console
ruby scripts/dependabot_waivers.rb verify .github/dependabot-waivers.json owner/repo
```

The registry deliberately lives in the repository it describes, not here: this
repository is public, and a central list of unpatched vulnerabilities in private
repositories would publish an attack surface. Each waiver must carry prose
explaining *why* the alert cannot be actioned and the evidence for it, because
GitHub has no dismissal reason meaning "upstream shipped no patch" — the
checker rejects a waiver that omits it, and rejects one whose own recorded
evidence admits an available fix.

### Arming the audit

The workflow is gated on the `DEPENDABOT_WAIVER_AUDIT` variable and stays
skipped until two things a workflow cannot do for itself are done by hand:

1. Grant the `harn-release-bot` GitHub App the **Dependabot alerts:
   read and write** repository permission (App settings → Permissions), and
   accept the permission change on the organization installation. Reopening an
   alert is a write; nothing less will do.
2. Set the repository or organization variable `DEPENDABOT_WAIVER_AUDIT` to
   `enabled`.

Until then the job reports as skipped rather than running red every week, since
a permanently failing alarm is the failure mode this whole mechanism exists to
prevent.

## Eval fixture repositories

`burin-labs/burin-example-*` repositories are **eval fixtures**, not products.
The Burin eval harness provisions them to `~/projects/burin-examples/<lang>` and
measures agent behaviour against those trees.

**The root cause is on the consumer side, not here.** The harness consumes a
fixture at the *branch tip*, never at a pinned revision:
`clone-golden-fixture.sh` runs `git clone --depth=1 --single-branch` with no
ref, `clone-eval-fixtures.sh --update` runs `git pull --ff-only`, and the
revision recorded at grading time (`fixtureRevision`) is a `rev-parse HEAD`
observation that is never compared against an expected value. So every commit on
a fixture's default branch silently moves the ruler, and two machines that
provisioned on different days measure different trees under the same cell name.

Dependabot was merely the loudest writer. `burin-example-ruby` took 63 Dependabot
pull requests, and 28 of the 39 commits on its `main` since 2026-05-01 were
dependency bumps. A human fixing a typo is the same hazard, smaller.

Pinning fixture revisions at the consumer is the durable fix and is tracked in
`burin-labs/burin-code#6935`. Everything below is a stopgap with an explicit
expiry, not the design.

### Interim posture

- **No `.github/dependabot.yml` in a fixture.** The `templates/dependabot.yml`
  projection and `check-dependabot-config` do not apply. The file's presence is
  the only switch for version updates, and pure version bumps are noise against
  a fixture under any pinning scheme. This part is permanent.
- **Dependabot automated security fixes disabled** at repository settings
  (`DELETE /repos/{owner}/{repo}/automated-security-fixes`). This is what
  produces Dependabot pull requests in a repository that has no config file at
  all, and it is the setting most people miss. **This part is temporary.**
- **Dependabot alerts stay enabled.** The vulnerability signal is kept; it is
  only forbidden from opening a pull request by itself.

Nothing security-relevant was suppressed when this was applied: across all 19
fixtures there were 0 open Dependabot pull requests and 0 open Dependabot alerts.
The 163 alerts in fixture history are all `fixed`, apart from 5 dismissed by hand
as `not_used`.

### Exit condition

Once `burin-code#6935` lands and fixture revisions are pinned at the consumer,
reproducibility no longer depends on freezing these repositories, and **security
updates should be turned back on**:

```sh
gh repo list burin-labs --topic eval-fixture --limit 200 \
  --json name -q '.[].name' |
while read -r r; do
  gh api -X PUT "repos/burin-labs/$r/automated-security-fixes"
done
```

Several of these repositories are public and are read, copied, and trained on.
A fixture carrying a knowingly vulnerable pin teaches the wrong pattern, so the
resting state is security-only Dependabot on a SHA-pinned fixture — not silence.
Version updates stay off either way.

New fixtures are born quiet: the organization's
`dependabot_security_updates_enabled_for_new_repositories` and
`dependabot_alerts_enabled_for_new_repositories` defaults are both off. That is
the current default, not the target one; a fixture created after #6935 should be
given security-only Dependabot deliberately.

Every fixture carries the topics `eval-fixture` and `no-dependabot`, which make
the membership of this class one query rather than a naming guess:

```sh
gh repo list burin-labs --topic eval-fixture --limit 200 --json name
```

Auditing the posture, when you want to confirm it rather than trust it:

```sh
gh repo list burin-labs --topic eval-fixture --limit 200 \
  --json name -q '.[].name' |
while read -r r; do
  fix=$(gh api "repos/burin-labs/$r/automated-security-fixes" --jq '.enabled')
  cfg=$(gh api "repos/burin-labs/$r/contents/.github/dependabot.yml" \
    --jq '.path' 2>/dev/null) || cfg=none
  printf '%-26s autofix=%s config=%s\n' "$r" "$fix" "$cfg"
done
```

## CI latency policy

`.github/actions/ci-latency-policy` checks a repository's
`.github/ci-latency.json` against its CI workflow. The policy names the
end-to-end SLO, the jobs that distinguish a full run from a fast lane, and a
budget for every job required by the aggregate status job.

Call the action from an existing source-only CI job so the check does not add a
runner:

```yaml
- uses: burin-labs/.github/.github/actions/ci-latency-policy@<full-commit-sha>
  with:
    baseline-sha: >-
      ${{ github.event.pull_request.base.sha ||
          github.event.merge_group.base_sha || '' }}
    github-token: ${{ github.token }}
```

The token needs `contents: read` only. When `baseline-sha` is present, the
action reads the policy at that commit and rejects increases to the
critical-path allowance or an existing job budget. It also rejects missing or
stale required-job entries, empty sentinel sets, invalid SLO ordering, and a
same-topology observed baseline that is removed, tampered with, or loosened.

Runtime measurement belongs off the pull-request path. The organization-level
observer runs every six hours and on demand. It uses Harn's
`scripts/ci_walltime_report.harn` implementation and the existing release-app
installation token with `actions: read` and `contents: read`. It runs on this
public repository's standard Linux runner, so observing private repositories
does not consume their hosted-runner minutes. The observer executes no code or
artifacts from measured workflow runs. It emits a job summary, retains compact
JSON reports for seven days. Product-target misses are first-class target-debt
receipts and remain visible without making every schedule red. The observer
fails on a sustained p90 regression past the reproducible observed baseline or
one run past its max-latency regression fuse. Missing, stale, invalid, or empty
evidence also fails closed. A same-topology baseline may only tighten.

Package repositories should keep the exact release in `.harn-version`.
Their complete CI adapter delegates package verification and rolls every
required job into one stable status check:

```yaml
jobs:
  package:
    uses: burin-labs/.github/.github/workflows/harn-package.yml@<full-commit-sha>

  status:
    name: CI status
    if: always()
    needs: [package]
    runs-on: ubuntu-latest
    steps:
      - uses: burin-labs/.github/.github/actions/require-successful-needs@<same-full-commit-sha>
        with:
          results-json: ${{ toJSON(needs.*.result) }}
```

Product-specific verification jobs belong beside `package` and in the status
job's `needs` list. The co-versioned status action validates every dependency
result and fails on failure, cancellation, skipping, or malformed data. It
receives no dependency outputs. This prevents a green roll-up from hiding a
failed package job and replaces repository-local shell expressions with one
tested contract.

When a package needs deterministic repository-specific checks but no distinct
runner, pass them through the workflow's optional `validate-command`. It runs
after the canonical package contract under the same installed Harn version and
read-only permissions. Keep a separate job only when the check needs a distinct
runner, permission boundary, service, or independently visible result.

Repositories that must compose package verification into an existing job can
instead use the composite action after checkout:

```yaml
- uses: burin-labs/.github/.github/actions/harn-package@<full-commit-sha>
  with:
    strict: "true" # opt in to strict type and lint gates
```

The action is a GitHub adapter only. Package policy and receipt semantics
belong to `harn package verify`.

On GitHub.com, the reusable workflow checks out `job.workflow_repository` at
`job.workflow_sha` under Harn's excluded `.harn/` directory and invokes the
composite action from that checkout. GitHub Enterprise Server does not expose
those called-workflow identity fields, so the workflow fails early with a
specific unsupported-platform error there.
The workflow and its adapter therefore share one immutable version; there is
no second self-pin that can silently trail a newly forwarded input.

The reusable workflow delegates warning-fatal check/lint gates and strict
boundary typing to Harn's canonical package contract by default. Burin Labs
package CI may not opt out. The lower-level composite action keeps strict mode
explicit so callers outside the organization choose their own admission
policy.

Strict verification requires Harn v0.10.52 or later, where `harn package
verify --strict` became part of the typed package contract. That release also
moves package verification receipts from schema v1 to v2 and adds the
`strict_requested` field on every receipt.

The daily reusable-workflow audit compares each exact pin with current workflow
content. It structurally verifies that every `needs.<job>.outputs.<name>` read is
declared by both the pinned and current workflow. This network-backed contract
belongs here; consumer repositories keep only offline pin-shape checks.

For callers owned by `burin-labs`, the package workflow also applies
`.github/actions/harn-repo-policy`. That action checks organization
projections—the managed agent contract, its `CLAUDE.md` symlink, and
connector-local guidance boundaries—while Harn owns package semantics. Public
callers receive the same package verification and receipts without inheriting
Burin Labs repository governance.

## Release integrity

These repositories publish by pushing a tag, so the manifest version, changelog
notes, and package verification are all checked against an object that is
already immutable and signed. A gate that fails there cannot be repaired in
place: the version is burned and the tag is left with nothing behind it. That is
how `harn-github-connector` accumulated `v0.6.1` (tagged a commit whose
`harn.toml` still read `0.6.0`) and `v0.6.7` (a release gate that only failed in
the release environment). Neither was noticed until someone went looking.

`harn-repo-policy` therefore asserts, on every package CI run, that every
`vX.Y.Z` tag has a published GitHub release, that no release is left as a draft,
and that no release outlives its tag. A tag pushed within
`release-integrity-grace-seconds` (one hour by default) is treated as still in
flight, so the release commit's own CI does not race the publishing job.

The check is deliberately narrow: it only recognizes `vX.Y.Z`, so deployment
markers and upstream naming schemes are left alone.

## Merge overrides

Use these labels when the normal merge queue or required `CI status` check is
the wrong tool for a rare, time-sensitive land. Labels are the trigger;
organization or repository admin membership is the authority. The reusable
workflow rejects non-admins and fork pull requests, then acts with the
`harn-release-bot` installation token (a ruleset bypass actor).

- `bypass-ci`: cancel competing runs for the head SHA and publish a successful
  `CI status` check after those runs stop. Does not merge. If GitHub cannot
  stop a run within two minutes, the override fails closed instead of racing
  that run's final status.
- `bypass-merge-queue`: squash-merge immediately when `CI status` is already
  green. Skips the merge queue but does not override CI. An in-flight check is
  reported as in flight, not missing.
- `force-merge`: publish successful `CI status`, then squash-merge immediately.
  Skips CI proof and the merge queue.

Override attempts are serialized per pull request. If several labels are
attached before an attempt starts, the workflow consumes them together and
selects the strongest request: `force-merge`, then `bypass-merge-queue`, then
`bypass-ci`. Its cancellation sweep excludes every run of the override
dispatcher, so concurrent label events cannot cancel one another.

### When to use an override

- The merge queue is backed up enough that speculative CI would burn material
  Actions spend, and one PR must land before the rest.
- Required CI is broken in a way you can fix forward on `main` within the same
  working session.
- You need to serialize a single founder land ahead of a long queue (release
  unblock, production incident, or similar).

### When not to use an override

- Ordinary feature work, dependency bumps, or “CI is slow today.”
- Changes you cannot fix forward if they break `main`.
- Pull requests from forks (the workflow refuses them).

### How to apply

1. Confirm you are an organization owner/admin or repository admin.
2. On a same-repo PR, add the label whose meaning matches the intended action.
3. Read the terminal audit comment. It records the selected request, every
   consumed label, the re-checked actors, the actions taken, and whether the
   attempt was applied, refused, or errored.
4. The workflow removes each consumed label on every terminal path. A label
   that remains attached therefore represents a pending or active attempt. For
   a refusal or error, follow the audit comment's reason and re-apply the named
   label to retry.

Organization admins can also use GitHub’s “Bypass rules and merge” UI: the
org-wide `main protection` ruleset grants `OrganizationAdmin` bypass in
`pull_request` mode.

### Wire a repository

Copy `templates/merge-override-dispatch.yml` to
`.github/workflows/merge-override-dispatch.yml` and pin the reusable workflow
to the full commit SHA of this repository that introduced or last changed
`merge-override.yml`. Keep its `issues: write` permission: the reusable workflow
uses the issue event history to re-check who applied every coalesced label and
removes those labels at terminal completion. Create the three labels once:

```bash
for name in bypass-ci bypass-merge-queue force-merge; do
  gh label create "$name" --repo burin-labs/<repo> \
    --color B60205 \
    --description "Privileged merge/CI override (org admin only)" \
    2>/dev/null || true
done
```

Public repositories stay in scope: applying a label still requires triage or
higher, and the workflow re-checks organization or repository admin permission
before any privileged action.

## Organization defaults

- `.github/pull_request_template.md` is inherited by repositories that do not
  carry a local override.
- `templates/dependabot.yml` is the authoritative projection for repositories
  using GitHub Actions. Dependabot does not inherit organization community
  files, so Harn package repositories project it byte-for-byte at the start of
  `.github/dependabot.yml`; repository-specific ecosystem entries may follow.
  The reusable package workflow enforces the projection.
- `.github/actions/check-dependabot-config` is the shared, flake-free checker
  for Dependabot *delivery* policy: every update entry needs a catch-all group
  (block or inline `patterns`), every committed lockfile needs a matching
  ecosystem entry, Cargo workspace members and path deps must stay inside the
  configured `directory`, and exact `pnpm-workspace.yaml` overrides need a
  `# pin:` annotation. It uses Ruby/Psych only — no network, no Harn binary —
  so always-on hygiene jobs can call it. The reusable `harn-package.yml`
  workflow runs it for every Burin Labs package CI caller. Product monorepos
  that do not use that workflow should call the action from an always-on job.
  Fleet prose for schedule/grouping lives in `harn-bump-fleet`; Harn-local
  family membership stays in Harn.
- Repositories carrying the `eval-fixture` topic are **excluded** from the
  projection permanently, and from the automated-security-fix posture only until
  `burin-code#6935` pins fixture revisions at the consumer. See *Eval fixture
  repositories* for why, the exit condition, and the audit command.

```yaml
- uses: burin-labs/.github/.github/actions/check-dependabot-config@<full-commit-sha>
  with:
    # Optional anti-vacuity for repos that always ship lockfiles / overrides:
    require-lockfiles: "true"
    require-overrides: "true"
```

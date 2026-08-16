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
stale required-job entries, empty sentinel sets, and invalid SLO ordering.

Runtime measurement belongs off the pull-request path. The organization-level
observer runs every six hours and on demand. It uses Harn's
`scripts/ci_walltime_report.harn` implementation and the existing release-app
installation token with `actions: read` and `contents: read`. It runs on this
public repository's standard Linux runner, so observing private repositories
does not consume their hosted-runner minutes. The observer executes no code or
artifacts from measured workflow runs. It emits a job summary, retains compact
JSON reports for seven days, and fails on a sustained p90 breach or one run past
the hard maximum. A single p90 window warns without paging, which keeps one-off
runner contention visible without creating alert churn.

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
  green. Skips the merge queue.
- `force-merge`: publish successful `CI status`, then squash-merge immediately.
  Skips CI proof and the merge queue.

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
2. On a same-repo PR, add exactly one override label.
3. Read the audit comment the workflow posts. For `force-merge` /
   `bypass-merge-queue`, confirm the PR merged.
4. Remove the label after the land if you want a clean label set; the audit
   comment remains.

Organization admins can also use GitHub’s “Bypass rules and merge” UI: the
org-wide `main protection` ruleset grants `OrganizationAdmin` bypass in
`pull_request` mode.

### Wire a repository

Copy `templates/merge-override-dispatch.yml` to
`.github/workflows/merge-override-dispatch.yml` and pin the reusable workflow
to the full commit SHA of this repository that introduced or last changed
`merge-override.yml`. Create the three labels once:

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

```yaml
- uses: burin-labs/.github/.github/actions/check-dependabot-config@<full-commit-sha>
  with:
    # Optional anti-vacuity for repos that always ship lockfiles / overrides:
    require-lockfiles: "true"
    require-overrides: "true"
```

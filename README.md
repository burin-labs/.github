# .github

Burin Labs organization defaults and reusable GitHub Actions workflows.

## Reusable workflows

- `.github/workflows/runner-availability.yml` detects idle self-hosted Linux,
  macOS, and Windows runners and falls back to GitHub-hosted runners when the
  pool is busy, unavailable, or inaccessible from a fork/dependabot run.
- `.github/workflows/harn-package.yml` checks out a Harn package, installs its
  exact `.harn-version`, runs the Harn-owned package contract, and uploads the
  structured receipts.

## Self-hosted runner health

`.github/runner-fleet.json` is the typed inventory of Burin Labs-owned runners.
The hourly `Self-hosted runner health` workflow takes two read-only GitHub
snapshots one minute apart and fails only when the same expected runner remains
missing or offline in both. Exact names exclude Blacksmith's short-lived runner
registrations. The workflow uploads a compact seven-day report and never
restarts a host; machine-local remediation remains an explicit idle-only
operation.

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
  `CI status` check. Does not merge.
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

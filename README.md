# .github

Burin Labs organization defaults and reusable GitHub Actions workflows.

## Reusable workflows

- `.github/workflows/runner-availability.yml` detects idle self-hosted Linux,
  macOS, and Windows runners and falls back to GitHub-hosted runners when the
  pool is busy, unavailable, or inaccessible from a fork/dependabot run.
- `.github/workflows/harn-package.yml` checks out a Harn package, installs its
  exact `.harn-version`, runs the Harn-owned package contract, and uploads the
  structured receipts.

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

## Organization defaults

- `.github/pull_request_template.md` is inherited by repositories that do not
  carry a local override.
- `templates/dependabot.yml` is the authoritative projection for repositories
  using GitHub Actions. Dependabot does not inherit organization community
  files, so Harn package repositories project it byte-for-byte at the start of
  `.github/dependabot.yml`; repository-specific ecosystem entries may follow.
  The reusable package workflow enforces the projection.

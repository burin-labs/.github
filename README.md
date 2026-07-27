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
Their complete CI adapter is one job:

```yaml
jobs:
  package:
    uses: burin-labs/.github/.github/workflows/harn-package.yml@<full-commit-sha>
```

Repositories that must compose package verification into an existing job can
instead use the composite action after checkout:

```yaml
- uses: burin-labs/.github/.github/actions/harn-package@<full-commit-sha>
```

The action is a GitHub adapter only. Package policy and receipt semantics
belong to `harn package verify`.

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

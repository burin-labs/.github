# .github

Burin Labs organization defaults and reusable GitHub Actions workflows.

## Reusable workflows

- `.github/workflows/runner-availability.yml` detects idle self-hosted Linux,
  macOS, and Windows runners and falls back to GitHub-hosted runners when the
  pool is busy, unavailable, or inaccessible from a fork/dependabot run.

Package repositories should keep the exact release in `.harn-version`.
Repositories with an existing job graph can use the package composite action
after checkout:

```yaml
- uses: burin-labs/.github/.github/actions/harn-package@<full-commit-sha>
```

The action is a GitHub adapter only. Package policy and receipt semantics
belong to `harn package verify`.

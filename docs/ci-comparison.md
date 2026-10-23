# CI comparison commits

Use `.github/actions/ci-comparison` after a full-history checkout with
`persist-credentials: false`. Pin the action to an exact released commit.

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
  with:
    fetch-depth: 0
    persist-credentials: false
- uses: burin-labs/.github/.github/actions/ci-comparison@COMMIT_SHA
  id: comparison
  with:
    base-ref: refs/remotes/origin/main
```

`base-sha` is the single merge base between `base-ref` and `head-ref`.
`base-tip-sha` and `head-sha` capture both resolved commits. Pass the same
`base-sha` and `head-sha` to path filters and affected-test planners. For a
stacked pull request, comparing to main's merge base includes its parent
changes and excludes later main changes that the candidate does not contain.

The action reads local Git history and makes no network request. Missing refs,
unrelated histories, and multiple merge bases fail before publishing outputs.
It does not decide which jobs run or which branch owns integration.

`head-ref` defaults to `HEAD`. `harn-version` defaults to `0.10.174`.
Set `skip-harn-setup: "true"` when that runtime is already on PATH.

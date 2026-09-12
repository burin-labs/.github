# Check Harn examples

Use `burin-labs/.github/.github/actions/check-harn-docs` to check Harn examples
with the same checker used by Harn itself. The action pins the runtime and checker
source. Your repository owns which documents to scan and how strictly to check
its examples.

Check out your repository, then call this action at an exact commit. Its `config`
input defaults to `.harn-docs.toml`; `working-directory` defaults to the repository
root. The checker fails on invalid policy, malformed examples, and a scan with no
checked examples. The action does not rewrite documents or diagnostic snapshots.
Its `log` output names the retained checker log, which is also printed after
validation so a failed check keeps its explanation.

For a README with partial examples, start with this policy:

```toml
version = 1
include = ["README.md"]

[defaults]
validation = "parse"
format = true
lint = "off"
line_width = 74
```

Use `validation = "check"` for complete examples whose names and imports resolve.
A `harn,check` fence also requests full checking. Mark intentional fragments with
`harn,ignore`; ignored fragments do not count as checked examples. The checker
source is fetched without Markdown, so it cannot make an empty consumer scan
appear to pass.

See Harn's [checker guide](https://github.com/burin-labs/harn/blob/main/docs/src/dev/check-docs-snippets.md)
for ordered policy rules and expected diagnostic examples.

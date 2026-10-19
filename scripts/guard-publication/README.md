# Publish a guard qualification

The qualification workflow computes the record from the current Burin wrapper,
stages only `scripts/harn-required-review/qualified-guard.json`, and invokes
`publish.harn` with the checkout, its current commit, and the Burin revision.
This package pins the released GitHub worktree adapter independently of the
older runtime used by the shared review controls.

An open qualification pull request owns its branch. Wait for its terminal result
before proposing another record. A moved branch or an unchanged orphan branch
requires inspection; the publisher never force-resets it. Stale heads, unsupported
index changes, and unverified signatures stop before pull request creation or
shipping. No release or public download is produced by this workflow.

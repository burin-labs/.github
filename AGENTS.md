# Engineering guidance

This repository owns shared GitHub Actions workflows and organization policy.
Keep policy in typed contracts and verify every projection that consumes it.

## Script language

- Use Harn for every script that runs after `setup-harn`.
- Bash is limited to the bootstrap that installs Harn and dispatches the Harn
  entrypoint.
- Do not add Ruby scripts. When work touches an existing Ruby script, migrate
  that script to Harn as part of the change.

## GitHub identity

Author as `burin-labs-agent`, act as control through the `burin-control` App,
and keep bulk reads off user tokens. See
[Agent GitHub identities](docs/agent-identity.md).

Pull request areas are `CI`, `Actions`, `Labels`, `Templates`, `Docs`, and
`Skills`.

<!-- BEGIN HARN SHARED AGENT CONTRACT: managed by harn-bump-fleet -->

## Ecosystem working agreement

- Build ambitious outcomes behind small typed interfaces; give behavior one owner
  and generate or parity-test projections instead of duplicating policy.
- Work autonomously within approved scope. Pause for destructive or production
  effects, exceptional spend, material ambiguity, or new authority.
- Treat stop, wait, stand down, pivot, and steer as control events.
- Use the smallest owning product-path check. Add a falsifier for contested,
  load-bearing, or potentially vacuous claims; record controls, recovery, and
  blind spots.
- Evidence follows source/artifact identity. Reuse proof when relevant code,
  build inputs, and dependencies are unchanged. Repeat affected checks for
  relevant changes, failures, deployment, or packaging differences. Do not
  rebuild or recapture solely for main.
- Ship means owning-main integration with terminal merge and applicable
  release/deploy checks. Confirm landed content and result; an open PR is
  incomplete.
- Use `ship` where deployed; otherwise use protected PRs: queue when required,
  or squash with `--match-head-commit` after required reviews/checks. Never
  `--admin` or bypass protections.

<!-- END HARN SHARED AGENT CONTRACT -->

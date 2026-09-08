# Engineering guidance

This repository owns shared GitHub Actions workflows and organization policy.
Keep policy in typed contracts and verify every projection that consumes it.

## Script language

- Use Harn for every script that runs after `setup-harn`.
- Bash is limited to the bootstrap that installs Harn and dispatches the Harn
  entrypoint.
- Do not add Ruby scripts. When work touches an existing Ruby script, migrate
  that script to Harn as part of the change.

Pull request areas are `CI`, `Actions`, `Labels`, `Templates`, `Docs`, and
`Skills`.

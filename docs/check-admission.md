# Check admission reference

The `burin-ci-checks/check_admission` module selects the current checks for
Smart Ship and read-only adapters. It performs no network or merge operations.

## Current checks

`current_checks(checks: list<Check>, head: string) -> list<Check>` returns a
subset of its input, in input order. The caller must supply a complete check
census for one stable head. An empty result does not prove that CI passed.

For check runs, the producer is the app ID, workflow ID, and check name.
The highest numeric `databaseId` supersedes earlier attempts, including
attempts created in the same second. Commit statuses use creator, check name,
and creation time. A tie or unknown producer never supersedes another record.

A cancelled or stale matrix placeholder yields only to a newer run with the
same workflow, head, and event. That run must be wholly green, with every
declared check observed and terminal.

## Types and helpers

[`Check`](../scripts/smart-ship/check-admission.harn) declares the accepted
GitHub metadata. Its optional identity fields allow incomplete evidence to
remain visible instead of hiding another attempt.

`generation(check: Check, head: string) -> string?` identifies the app,
workflow, head, and event, or returns `nil` when any identity is missing.
`run_id(check: Check) -> int` returns the workflow run ID, or zero when absent.
`RERUN` lists the retryable conclusions `CANCELLED` and `STALE`.

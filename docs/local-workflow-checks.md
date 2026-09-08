# Local workflow checks

The `burin-ci-checks/local_checks` module turns a GitHub Actions workflow into
a local execution plan. The workflow owns commands, working directories,
shells, timeouts, and environment values. A repository-owned JSON policy adds
only facts the workflow cannot supply, such as platform support, heavyweight
build wrapping, and checks that require GitHub-hosted state.

Job-level workflow conditions select CI lanes from event and changed-path
state. Declaring that job as a local check replaces that selection decision;
otherwise nearly every CI command would be unavailable outside GitHub. Explicit
step conditions remain authoritative and are reported as unavailable when the
local runner cannot evaluate them.

Call `parse_policy` once at the input boundary, pass its result with the
workflow text to `plan_checks`, then call `run_checks`. The runner continues
after independent failures and returns a `CheckReport` that names failed,
unmeasured, setup, and remote-only steps. `ok` stays false when the workflow
census is incomplete or when no check ran, so an empty read cannot certify the
repository.

Each command inherits only the host's runtime essentials, including `PATH`,
home, temporary-directory, operating-system, and locale variables. Workflow
and policy environment values override that base. Other ambient variables are
not forwarded, so a credential reaches a check only when its contract declares
it.

Consumer packages can expose the same CLI without copying its boundary:

```harn
import { run_cli } from "burin-ci-checks/local_checks_cli"

fn main(harness: Harness) -> int {
  return run_cli(harness, argv)
}
```

Use the package command for a local run:

```sh
harn run scripts/local-checks/cli.harn -- \
  --workflow .github/workflows/ci.yml \
  --policy .github/local-checks.json
```

Repositories use the composite action from an immutable commit:

```yaml
- name: Run local workflow checks
  uses: burin-labs/.github/.github/actions/local-workflow-checks@<40-character-commit>
  with:
    harn-version-file: .harn-version
    workflow: .github/workflows/ci.yml
    policy: .github/local-checks.json
```

The action installs the exact Harn release named by `harn-version-file`. Pass
`harn-version` only in repositories that do not own a version file. Checks
marked `heavy` share a repository build lock by passing its comma-separated
argument vector as `build-wrapper`. A heavy check without that wrapper is
reported as unmeasured and does not start.

GitHub expressions in step conditions, commands, environment values, working
directories, and timeouts stay visible in the plan. The runner reports the
affected check as unmeasured instead of guessing the expression's value.

A disposition can add `"groups": ["precommit"]`. Passing `--group precommit`
or the action's `group` input runs only those checks, while the planner still
censuses the complete workflow and policy. A group with no measured check and
any missing workflow coverage both fail, so a fast hook remains a strict subset
of the same contract instead of becoming a second command list.

The policy schema is versioned. Each workflow job needs one `jobs` entry.
Named step overrides must still exist in the workflow, and a deleted job or
override fails the census as stale configuration.

```json
{
  "version": 1,
  "jobs": {
    "checks": {
      "disposition": {
        "kind": "check",
        "platforms": ["linux", "macos"],
        "heavy": true
      },
      "steps": {
        "Prepare fixture": {
          "kind": "setup",
          "reason": "creates input for later checks"
        }
      }
    },
    "publish": {
      "disposition": {
        "kind": "remote",
        "reason": "requires GitHub release authority"
      }
    }
  },
  "actions": {
    "actions/checkout": {
      "kind": "setup",
      "reason": "the local workspace is already checked out"
    }
  },
  "environment": {
    "LOCAL_CHECK_MODE": "true"
  }
}
```

`jobs.<name>.disposition` supplies the default for shell steps and covers the
whole job when its kind is `setup` or `remote`. A named step override has the
highest priority. In a checked job, action steps use the matching unversioned
action entry, such as `actions/checkout` for any immutable checkout revision.
Every `setup` or `remote` disposition requires a reason.

An explicit workflow step `id` is its policy key. Otherwise the visible step
name is the key. Duplicate visible names share one override; give the steps
distinct IDs when their local dispositions differ. Unnamed steps receive a
stable positional label for reporting and do not require duplicate commands to
be rewritten.

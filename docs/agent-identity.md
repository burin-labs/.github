# Agent GitHub identities

Reference for which GitHub identity an agent uses for each action in burin-labs
repositories, how to act as the control App, and how to stay inside GitHub's
rate limits.

## Identities

- `burin-labs-agent`: machine user, the default `gh` and git identity. Authors
  work.
- `burin-control[bot]`: GitHub App 5413304, installed on every repository.
  Control actions and bulk reads.
- `burin-code-reviewer[bot]`: GitHub App for automated review, posted by the
  review workflow.
- `harn-release-bot[bot]`: GitHub App for release, override, and
  thread-resolution steps inside workflows. Agents never hold its key.
- `kennethsinder`: the founder. See
  [When to act as Kenneth](#when-to-act-as-kenneth).

## Action matrix

| Action | Identity |
| --- | --- |
| Commits, branches, pull requests, issues, thread replies | `burin-labs-agent` |
| Automated review | `burin-code-reviewer[bot]` |
| Control approval after a fresh-context review | `burin-control[bot]` |
| Merge override and `review-override` labels | `burin-control[bot]` |
| Finding dispositions | `burin-control[bot]` |
| Merge queue and auto-merge operations | `burin-control[bot]` |
| Self-hosted runner administration | `burin-control[bot]` |
| Bulk reads, polling, watchers, census crawls | `burin-control[bot]` |
| Releases | `harn-release-bot[bot]` |
| Organization settings, rulesets, App permissions, billing | `kennethsinder` |

- Sign commits, and never set a repository or worktree git identity.
- An App approval counts toward required reviews only while the App holds
  `contents: write`. Bind it to the reviewed head with `commit_id`.
- Override labels (`bypass-ci`, `bypass-merge-queue`, `force-merge`) are for
  incidents. Post `override: <reason>` as the same identity first.
- Dispositions (`/burin-disposition`, `/automated-disposition`) follow the same
  evidence rules as an administrator's.
- `gh pr merge --squash --auto` as `burin-labs-agent` also arms auto-merge.
- Releases run through the release workflows, never by hand.
- Change organization settings only inside a task that authorizes the change,
  and read back every change.

Never use `gh pr merge --admin`, an admin token to bypass protections, or a
weakened ruleset to land a pull request. An App cannot approve a pull request it
opened, so `burin-control[bot]` never authors pull requests.

## When to act as Kenneth

Act as `kennethsinder` only when the action should read as a person:

- Open-source maintainer interactions on public repositories, such as replies to
  outside contributors or issues and pull requests in another organization's
  repository, where a bot would look odd.
- Steps GitHub reserves for an owner: changing App permissions, accepting an
  installation's permission update, organization settings, and billing.
- Messages written in Kenneth's voice at his request.

Never act as Kenneth for routine approvals, labels, dispositions, polling, or to
get around a rate limit on another identity. An agent shell refuses another
account's token unless `GH_ADMIN_ACTION=<reason>` declares the admin action.

## Acting as the control App

`gh-app-token` runs one command with an installation token for
`burin-control[bot]` in `GH_TOKEN`. It installs with the fleet `gh` wrapper and
reads the App ID, installation ID, and key path from the fleet secrets file.

```sh
gh-app-token --check        # fresh token; print expiry and permissions
gh-app-token -- gh pr edit 123 --add-label force-merge
gh-app-token -- bash loop.sh  # one credential for a whole loop
```

- The token never reaches stdout, argv, logs, or shell history. Never print it,
  pass it as an argument, or copy it into a file.
- The token is cached in a `0600` file until five minutes before it expires, so
  repeated calls reuse one credential.
- `gh-app-token --check` replaces the cache, so a permission change takes effect.

## Rate limits

Measured 2026-10-25 with fresh tokens:

| Credential | REST per hour | GraphQL points per hour |
| --- | --- | --- |
| Each user token | 5,000 | 5,000 |
| `burin-control[bot]` installation | 15,000 | 10,000 |

A user token's budget is shared by every agent and script on that account. The
App's budget is shared by every holder of a `burin-control[bot]` token.

Rules:

1. Run bulk reads, polling, watchers, and crawls under `gh-app-token`. Keep the
   machine user's budget for authoring.
2. Batch reads in one GraphQL query instead of one REST call per object. Request
   only the fields you read.
3. Send conditional requests. A `304 Not Modified` answer to `If-None-Match`
   costs nothing; the `gh` wrapper does this for `gh api` reads.
4. Keep the `gh-budget` wrapper first on `PATH`. When it exits `75`
   (`RATE_LIMITED`), wait until the time it names. Do not switch identity.
5. Poll no faster than once a minute, and stop a watcher at its iteration cap.
6. Measure a bucket with a freshly minted token:
   `GH_APP_TOKEN_FRESH=1 gh-app-token -- gh api rate_limit`. A cached App token
   has read a different counter than the bucket in use.

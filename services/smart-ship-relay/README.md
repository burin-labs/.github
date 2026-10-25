# Smart Ship thread relay

Starts a Smart Ship look at one pull request within seconds of a review
conversation being resolved or reopened. GitHub Actions has no trigger for that
event, so without this service the change waits for the next 15-minute sweep.

The service receives GitHub's `pull_request_review_thread` webhook and calls
`workflow_dispatch` on the repository's Smart Ship caller with `pr=<number>`.
It starts no Actions run unless the delivery is signed, is a `resolved` or
`unresolved` action, belongs to an allowlisted repository, and concerns an open
pull request carrying the `ship` label.

## Reference

Routes: `POST /hooks/github` (webhook), `GET /healthz`.

- `GITHUB_WEBHOOK_SECRET`: the organization webhook secret. Every delivery is verified
  with `X-Hub-Signature-256` in constant time.
- `GITHUB_APP_ID`: the App whose installation token dispatches the workflow.
- `GITHUB_APP_PRIVATE_KEY`: the App's PEM private key.
- `RELAY_REPOS`: a JSON object of `owner/name` to caller workflow file, for
  example `{"burin-labs/harn":"smart-ship.yml"}`.
- `PORT`: the listen port, default 10000.

The organization webhook sends only `pull_request_review_thread`. The dedicated
App needs `actions: write` and is installed only on the admitted repositories;
it needs no webhook subscription. The relay resolves that App's installation
for the admitted repository, because organization deliveries have no App
installation field. Each dispatch token is limited to that one repository
with `actions: write`.

Each caller workflow must declare a `pr` input under `workflow_dispatch`;
without it GitHub rejects the dispatch with 422 and the delivery answers 502.

Answers: 401 for a bad signature, 202 for a dispatch or a deliberate skip
(wrong event or action, unlabeled or closed pull request, unlisted repository,
duplicate delivery id), 502 when the GitHub API refused, so a redelivery can
retry. Duplicate suppression is in memory; a restart can dispatch a repeated
delivery again, which costs one idempotent look.

## How to run the tests

```sh
cd services/smart-ship-relay
node --test
```

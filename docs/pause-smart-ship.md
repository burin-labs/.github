# Pause Smart Ship

Keep the `ship` label when you pause an automatic merge. Add `hold` or
`do-not-merge`, which the [landing gate](../scripts/smart-ship/ship.harn) checks
before it can merge or repair a PR.

## Pause a PR

1. Post a comment on the PR with the reason, the affected head SHA, and what
   must change before shipping can resume. A note on a separate board does not
   tell someone reading the PR why it stopped.
2. Add `hold` or `do-not-merge`. Keep `ship` so the request to land remains
   visible. If the repository lacks either hold label, ask its maintainer to
   create one before using it.
3. Read the labels back and confirm that both `ship` and the hold are present.
   Check the current head and merge state too; a merge may already have started
   before the hold was applied.

For example, after posting the reason, you can pause a PR with:

```sh
gh pr edit 42 --repo OWNER/REPO --add-label hold
gh pr view 42 --repo OWNER/REPO --json headRefOid,labels,state,mergeStateStatus
```

## Resume a PR

1. Confirm that the stated condition is met. If the head changed, obtain a
   review of that exact head and check its required results. An older approval
   does not approve a new head.
2. Post the resolution on the PR, then remove the hold. Keep `ship`.
3. Confirm that the next Smart Ship run read the current head. If a run has not
   started, use the caller's normal dispatch input to request a look. Follow
   the protected result through merge; a workflow's successful exit alone does
   not prove that it merged the PR.

## Stop shipping a PR

Remove `ship` only when you intend to withdraw the request to land it. First
post why you are withdrawing it and whether a later request is expected. A
removal made with an App token shows the App as the actor, so name the person
or coordinating session that made the decision in the comment.

After removal, read back the labels and any pending automatic merge request.
If you later decide to ship, add `ship` again and follow the protected result.
Do not remove and re-add it merely to retry a failed check.

The [held-PR test](../scripts/smart-ship/ship_test.harn) exercises the landing
gate with both hold labels. Smart Ship stops on either hold and does not write
to that PR. The shipping loop does not remove `ship` when checks or review
block a merge.

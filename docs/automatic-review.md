# Request a missed automatic review

Use this procedure when a ready pull request has no automatic review outcome.
New pull requests, reopened pull requests, ready-for-review changes, and pushes
request a review automatically. The reviewer may refuse a request when its
shared daily spending limit is occupied or the pull request head has moved.

1. Open **Actions** in this repository and select **Automatic review dispatch**.
2. Select **Run workflow** on the default branch, `main`.
3. Enter the pull request number and run the workflow.
4. Inspect **Resolve the current eligible head** in the workflow run. An eligible
   request records the current commit SHA. **Request a review of the measured
   head** confirms that the request was sent; the review itself arrives on the
   pull request.

Only open, ready pull requests with a person as author and a branch in this
repository are eligible. Forks, drafts, bot-authored pull requests, and closed
pull requests do not receive a request. An unread pull request fails the
workflow rather than being treated as eligible.

If a daily-limit refusal appears on the pull request, retry after the next UTC
day begins. If the head moved, its push requests another review automatically.
Inspect the review's commit SHA before relying on its verdict. Manual replay
uses the same admission checks and spending limits as an automatic request.

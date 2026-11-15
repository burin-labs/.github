# Call Smart Ship for a controlled main failure

Use this workflow after a repository's red-main responder has reproduced a
failure and measured a passing control at the preceding source boundary.
The responder owns attribution and the episode issue. Smart Ship supplies one
bounded repair agent and opens a draft fix PR for review.

Create a `workflow_dispatch` caller on the repository's main branch. Pass the
open episode issue number, its original red run ID, and the current main commit
to `.github/workflows/smart-ship-main-repair.yml` at an immutable organization
commit. Inherit the release App credentials and `OPENAI_API_KEY`. Persist a
dispatch intent before requesting the workflow; an accepted dispatch is not
evidence that its repair started.

The issue must carry the responder's `burin.main_red_episode.v2` state with a
controlled culprit and nonempty failing-job names. The worker re-reads the issue,
the source refs, both runs and complete job inventories before preparing a
checkout. It atomically records one attempt per issue and original red run.
An existing attempt, changed source, closed issue, missing job or skipped control
refuses before inference spend.

The agent receives the current checkout and bounded failure logs. It has no
GitHub credential or child network. The existing Smart Ship agent allows at
most 60 turns, $2, and 20 minutes. Publication runs outside that sandbox, rechecks
the source and episode, stages through Smart Ship's existing file policy, and
uses the existing signed-commit adapter. Only a nonempty repair reported as
fixed may open a draft PR. Its report does not approve the PR, satisfy CI, close
the episode or merge code.

Read the episode's linked Actions run for the actual preparation and repair
outcome. A timeout, missing report or refused publication leaves its checkout
under the run's `SHIP_WORK` directory for investigation while the runner retains
it. It does not dispatch another attempt automatically. Keep the episode open
until a later run actually passes its failing jobs.

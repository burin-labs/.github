# Release completion authorization

Ordinary promotion requires a completed successful producer at the requested
source. Harn may also provide `authorization-run-id` and
`authorization-attempt` when its original consumer observer reached its
deadline and the exact dispatched child later completed.

Harn owns which producer failures are eligible and which downstream product
steps and receipts prove completion. Its canonical promotion workflow writes
an attempt-bound authorization only after checking the original dispatch,
deadline refusal, complete producer and child censuses, and latest identities.
The original deadline remains unmeasured; the failed producer is not relabeled
successful.

Shared publication authenticates the main-branch promotion run, its successful
authorization job and required writer steps, and its unique attempt-named
artifact. The typed receipt must bind the requested source, producer attempt,
child identity and authorization attempt. Publication checks both latest run
identities again before accepting it. Missing or partial proof refuses.

This authorization changes only the producer-success prerequisite. Manifest,
archive digests, attestations, source ancestry, signing and publication checks
remain required. It neither rebuilds archives nor treats an equal Git tree as
permission to substitute another source revision.

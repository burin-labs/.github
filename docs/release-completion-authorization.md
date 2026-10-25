# Release completion authorization

Ordinary promotion requires a completed successful producer at the requested
source. Harn may also provide `original-consumer-context` when its original
consumer observer reached its deadline and the exact admitted child later
completed successfully with a reached product pass.

Harn owns which producer failures are eligible and which downstream product
steps and receipts prove completion. One immutable reader authenticates the
original issued context, reached deadline, complete producer and child
censuses, and latest identities. The declaration owns the observation clock;
the deadline's opaque commitment binds the same admitted child, attempt,
source and private receipt nonce. A replacement child cannot supply recovery.
The original observer still failed at its deadline; the failed producer is
not relabeled successful.

An explicit `consumer-repair` selector supplies a separate recovery mode.
Harn's reader authenticates a new manual promotion observer and the current
head of one open, same-repository consumer repair pull request. It proves the
original producing attempt's required builds, smokes and artifact handoffs
are complete, then requires a fresh reached product pass whose custody and
terminal receipt bind the original manifest artifact ID and SHA-256 digest.
Source-only receipts cannot authorize this mode. A later consumer failure
does not invalidate those completed archive stages; a missing or failed
archive stage still refuses. The original release run remains unchanged.

Shared publication invokes the pinned reader with a read-only App token
restricted to Harn and the configured consumer. Credentials and the consumer
identity travel through explicit environment grants. The reader returns only
public context and counts; private child identities, chronology and receipts
stay behind its boundary. Publication binds the returned original context to
the requested producer run, attempt and source, then re-reads it before
publishing. A later promotion's new context cannot authorize an older failed
candidate through original deadline recovery. Repair uses its distinct typed
decision and binds the original producer and manifest instead. The two modes
are mutually exclusive. Failed, empty, malformed or truncated reader output
refuses.

This authorization changes only the producer-success prerequisite. Manifest,
archive digests, attestations, source ancestry, signing and publication checks
remain required. It neither rebuilds archives nor treats an equal Git tree as
permission to substitute another source revision.

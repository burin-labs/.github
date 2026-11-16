# Smart Ship recovery storage

Smart Ship keeps unfinished repairs until it can prove that their source is safe
to remove. A successful publication, a terminal workflow or an absent file alone
doesn't provide that proof. The [recovery owner](../scripts/smart-ship/recovery.harn)
binds the producer, source and remote Git reference; the
[lifecycle owner](../scripts/smart-ship/lifecycle.harn) combines those facts with
worker retirement before reclaiming space.

## Capacity and ownership

Every look requires a Linux runner with util-linux `flock` and readable
`/proc/self`, including looks with repair disabled. The `runs-on` input selects
that runner; the default is `ubuntu-24.04`.

Each runner has a private recovery directory with a five-entry repair limit.
Active, legacy and unconfirmed entries all consume capacity. Reconciliation runs
before a look at a PR, including a green PR. A full directory stops a new repair
before its attempt marker, checkout or model spend. It doesn't prevent a green
PR from merging.

A repair reserves its entry before preparing or starting the worker. Its work
stays at `<store>/<run>-<attempt>-<PR>-<nonce>/work`; cleanup never moves an active
checkout. The sibling `<store>.lock` is a persistent kernel lock file. Trusted
transactions hold its exclusive lock and recheck its descriptor, inode and
directory identity before mutations. They never unlink the lock file or infer
ownership from its age.

The sandboxed worker runs in a separate step without that lock descriptor or a
GitHub token. Its trusted outer owner records the runtime artifact, terminal
outcome and canonical process-cleanup receipt. An interrupted outer owner can
leave retirement unconfirmed even if the child has exited. Such work stays in
the store.

## Evidence required for local cleanup

An entry is eligible only when all of these facts agree:

- The owned record, entry directory and work directory still have their measured
  identities.
- The authenticated producer is the exact repository, run and attempt, and is
  terminal.
- The canonical worker receipt confirms retirement under the measured runtime artifact.
- The current source tree, index, original detached HEAD and Git references match
  the recorded source.
- A live remote reference still names the recorded commit and tree.

If a later attempt moves the WIP reference, the exact content-addressed archive
can provide that custody. Reclamation keeps an archive when it is the confirmed
copy of the source, so a retry doesn't strand the old local entry or erase its
remaining remote copy.

Source capture uses the existing trusted Git owner. Unpublished ignored source,
changed staged contents, submodules, replaced paths and unreadable inventories
refuse reclamation. Missing or legacy records grant no cleanup authority.

The lifecycle writes a flushed cleanup intent under `<store>.lifecycle` before
removal. It conditionally replaces that same journal as progress changes, then
records the confirmed result. A retry remeasures every fact; historical progress
doesn't authorize another deletion. An entry absent after an interrupted intent
remains an unconfirmed outcome in the report.

## Archived checkpoints

Before replacing a previous checkpoint, publication preserves it at
`refs/smart-ship/previous/<PR>/<sha>`. Checkpoint publication and reconstruction
share the same Git diff settings. Literal path handling preserves renamed files,
leading dashes, newlines, wildcards and pathspec syntax.

An archived reference can be removed only when its exact SHA also has confirmed
live custody. The [GitHub adapter](../scripts/smart-ship/lifecycle-github.harn)
authenticates the repository and live content, checks the exact archive object,
then removes only that content-addressed reference. It preserves the caller's
mutation authority and checks the physical lock immediately before the request.
It never removes the mutable WIP reference through this cleanup path.

Deletion requires a fresh authenticated absence readback. An initially absent
archive requires fresh repository and live-content authentication followed by a
second absence read. Reports distinguish `removed` from `already_absent`.
Permission failures, unreadable responses, changed SHAs and failed readbacks keep
the local entry and unfinished intent for a fresh retry. Archives with different
SHAs remain retained and named in the report.

## Reports and production repair

The workflow logs a structured census with observed, remaining, reclaimed and
pending counts, named entries, archive outcomes and incomplete intents. A repair
refused for exhausted capacity posts one comment per head and fails its workflow
step, so the refusal is visible outside the PR. Green merges still proceed.

Repair remains disabled by default. This recovery lifecycle doesn't enable
production repair or replace the separate hosted credential falsifier and
five-case replay gates. For a temporary shipping pause, follow
[Pause Smart Ship](pause-smart-ship.md).
